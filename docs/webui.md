# Web UI

A local web interface to create, deploy and destroy clusters without installing
Terraform or editing tfvars by hand. It runs in a container on your workstation
and runs the same `cluster.sh` and `deploy.sh` as the command line. Design and
threat model: [ADR 009](decisions/009-webui-runner.md).

> **Alpha** (`alpha-0.0.2`): expect bugs and breaking changes between releases.
> Use test accounts and review every plan before applying it.
>
> Unofficial community project. Not affiliated with, endorsed or supported by
> SUSE.

## Run

The folder on the host holds all cluster data, credentials included. It must be
writable by UID 1000, the user inside the container.

```sh
mkdir -p ~/aif-clusters && chown 1000:1000 ~/aif-clusters   # Linux; may need sudo
docker run -d --init --name aif -p 127.0.0.1:8080:8080 --stop-timeout 600 \
  --read-only --tmpfs /tmp \
  -v ~/aif-clusters:/opt/aif/clusters \
  ghcr.io/e-minguez/suse-ai-factory-cloud-providers:alpha-0.0.2
```

With podman, map your user to UID 1000 and label the volume:

```sh
podman run -d --init --name aif -p 127.0.0.1:8080:8080 --stop-timeout 600 \
  --read-only --tmpfs /tmp \
  --userns=keep-id:uid=1000,gid=1000 \
  -v ~/aif-clusters:/opt/aif/clusters:Z \
  ghcr.io/e-minguez/suse-ai-factory-cloud-providers:alpha-0.0.2
```

`--init` reaps the child processes of the runner (it is PID 1). `--read-only
--tmpfs /tmp` keeps the root file system immutable: the container writes only
`/tmp` and the volume.

Image tags: `alpha-0.0.2` is the web UI version (`tools/webui/VERSION`) and moves to
the newest build of that version; `vX.Y.Z` is a repository
[release](https://github.com/e-minguez/suse-ai-factory-cloud-providers/releases)
and does not move. There is no `latest` tag while the web UI is alpha.
Keep `127.0.0.1` in `-p`: the UI can create billable resources, so do not
publish it on other interfaces.

Read the token URL from the log and open it in a browser:

```sh
docker logs aif | grep Open
# Open: http://127.0.0.1:8080/?token=...
```

The token is exchanged for a session cookie and removed from the address. A new
token is generated at every start; set `WEBUI_TOKEN` to keep one.

## Volume layout

Same as [`cluster.sh`](../tools/multicluster/README.md#working-area).

```
clusters/
  common-all.tfvars          values shared by every provider
  common-<provider>.tfvars   credentials and provider-wide values
  .aws/credentials           aws credentials
  .home/                     HOME of the container (mode 700)
    .evroc/config.yaml       evroc CLI configuration
    .ssh/id_ed25519          optional private key for kubeconfig download and ssh.sh
  <name>/                    one cluster: terraform.tfvars, state, .deploy/logs/
```

Directories are mode 700 and files 600. The volume contains credentials and
Terraform state, which contains secrets
([security](security.md#state-is-secret)).

## Account profiles

Open `Profiles` and pick a provider. Enter its credentials once (aws access key,
evroc configuration, vultr API key, exoscale API key and secret). The page edits
credentials only. Credentials are write-only: the page shows "set" or "not set",
and an empty field keeps the stored value. They stay on the volume so that a
later destroy works.

For evroc, paste the whole `~/.evroc/config.yaml` written by `evroc login`,
including `currentProfile`; the page checks that the current profile has a
refresh token. The container keeps its own copy, read by the provider and the
evroc CLI as `$HOME/.evroc/config.yaml`. If evroc later rejects the token (for
example after a new `evroc login` elsewhere), paste the current file again.

Values shared by clusters (`clusters/common-all.tfvars`,
`clusters/common-<provider>.tfvars`) are edited by hand on the volume or with the
CLI ([multicluster](../tools/multicluster/README.md)).

aws credentials are passed to Terraform only when saved on the profile page.
Otherwise the standard AWS environment variables work when passed to the
container, for example `-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e
AWS_REGION`.

The profile page can also store an existing SSH private key in
`clusters/.home/.ssh/id_ed25519` (see [Kubeconfig and SSH](#kubeconfig-and-ssh)).

## Create a cluster

1. `New cluster`: choose a provider and a name (lowercase letters, digits and
   `-`, starting with a letter).
2. Fill in the form. The cost estimate beside it updates as you type. It is an
   estimate, not a quote ([cost estimator](../tools/cost/README.md)).
3. Save. Values are written to `clusters/<name>/terraform.tfvars`.

### Basic and advanced settings

The basic form has what a first deploy needs: region, admin CIDRs (`Detect my
IP` fills yours), SSH keys, passwords, registry credentials and GPU pools.
`Advanced settings` opens the remaining variables in groups (Network,
Nodes, AI Factory, Access, Image and build, Provider, Tags). Defaults are shown
as placeholders. Only values you change are written; an empty field removes the
value from the file, so the module default applies. A marker shows when advanced
values differ from their defaults. Passwords are typed in clear and stored as
hashes. Variables that modules manage themselves are never shown.

List and map values that have no dedicated widget are JSON text areas, checked
against the variable type before saving.

### SSH keys

Add keys from any mix of sources:
- paste public keys, one per line (private keys are rejected);
- a GitHub user name (fetches `https://github.com/<user>.keys`);
- generate an ed25519 pair. The private key is offered for download once. A
  checkbox (on by default) also keeps a copy at
  `clusters/.home/.ssh/id_ed25519`, mode 600, which kubeconfig download and
  `ssh.sh` use inside the container. Untick it to keep no copy.

Each key is listed with type, size, fingerprint and source; untick keys you do
not want. Keys are resolved once and stored as text, with a comment naming the
source. Keys are part of the image and of the node `user_data`, so changing them
rebuilds the image and replaces all nodes. `Refresh from GitHub` shows the
difference first and warns about this.

The keys count against the `user_data` limit. The UI shows the running total:

| Provider | `user_data` limit |
|---|---|
| aws | 16 KiB (compressed) |
| exoscale | about 24 KiB |
| vultr | 32 KiB |
| evroc | 768 KiB |

## Deploy

Open the cluster and choose `Deploy`. The job page shows each pass, resources as
they are created, and the log. Before every apply the plan review lists what
will be created, replaced and destroyed. `Apply` continues, `Abort` stops with
nothing applied. Nothing is applied without this answer.

`Cancel` sends an interrupt to the running job. Only one job runs per cluster.

When done, the overview shows the outputs (Rancher URL and others). The image is
rebuilt only when its inputs change. To force it, use `Rebuild and deploy`
under "Other actions" on the cluster page.

## Destroy

`Destroy` (under "Other actions") asks you to type the cluster name and to
confirm once, then shows the same plan review.
Afterwards a button runs `tools/leftovers/<provider>.sh` (read-only) in the
container and shows the result. The image ships the aws and evroc CLIs the aws
and evroc checks need. Outside the image, when a CLI is not in `PATH`, the page
shows the command to run on a machine that has it. Check the result before
assuming the account is clean.

## Rancher bootstrap password

`Show Rancher bootstrap password` on the cluster page reads the sensitive
`rancher_bootstrap_password` output from the state on request (user `admin`).
It is not cached and not shown anywhere else. Change it in Rancher after the
first login.

## Kubeconfig and SSH

`Download kubeconfig` fetches the file through a POST request, with no caching.
It is a credential: store it with mode 600. The container reads it from the
init node over SSH, through the jumphost, so both the download and `ssh.sh`
need a private key that matches one of the cluster's SSH keys. The node
passwords do not help here: the jumphost accepts keys only, and the passwords
are meant for the console. The container finds a key in one of two ways:

- **A key file on the volume**: `clusters/.home/.ssh/id_ed25519`. The
  generated key is stored there by default, or paste an existing key on the
  profile page (see [SSH keys](#ssh-keys) and
  [Account profiles](#account-profiles)). Passphrase-protected keys cannot be
  stored; use the agent.
- **Your SSH agent**, with no key copied into the container. Add to `docker run`:
  - Docker Desktop (macOS, Windows):
    `-v /run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock -e SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock`
  - Linux: `-v "$SSH_AUTH_SOCK":/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent`

  The key must be loaded in the agent (`ssh-add -l`). The container user is
  UID 1000; if the socket refuses it, use the key file instead.

The cluster page shows a warning when neither is available.

SSH goes through the jumphost with the helper script in the container:

```sh
docker exec -it aif clusters/<name>/ssh.sh <host>
```

The hint on the cluster page shows the exact command.

## Logs

`Logs` on the cluster page lists the runs in `.deploy/logs/<timestamp>/` and
shows each file. Known secret values are redacted in the view; the files on the
volume are not redacted.

## Upgrade the image

Stop the container ([below](#stop-safely)), remove it and start the new tag with
the same volume:

```sh
docker stop -t 600 aif && docker rm aif
docker run -d --init --name aif ... ghcr.io/e-minguez/suse-ai-factory-cloud-providers:alpha-0.0.2
```

Cluster data stays on the volume. Provider plugin versions come with the image;
the next plan may show provider upgrades.

## Stop safely

```sh
docker stop -t 600 aif
```

Stopping during an apply can leave state locked or half written. On SIGTERM the
runner interrupts the running deploys and waits for Terraform to finish (up to
`WEBUI_STOP_TIMEOUT`, default 10 minutes, matching `--stop-timeout 600`; without
a stop timeout, Docker kills the container after 10 seconds). Wait
for running jobs to finish when you can.

Never use `docker rm -f` (or `docker kill`) while a job runs: it kills Terraform
at once, can leave created resources out of the state and leaves the state
locked. After that, remove `clusters/<name>/.terraform.tfstate.lock.info`, run
the leftovers check, and for evroc `tools/orphans/evroc` in the cluster
directory before deploying again. A lock left by an earlier container does not
block new jobs.

## Backups

Back up `~/aif-clusters` (or the folder you mounted). It holds credentials and
state; a deploy can not be destroyed or updated without it. Keep the backup
encrypted, and keep the folder on an encrypted disk. For long-lived clusters,
use an encrypted remote backend in the cluster directory instead of local state
([security](security.md#state-is-secret)).

## Use the same folder with the CLI

The layout is the one of `cluster.sh`, so a checkout can use the folder: link or
copy it to `clusters/` and run `tools/multicluster/cluster.sh list`, `deploy`
or `destroy` (see [multicluster](../tools/multicluster/README.md)). Do not run
the CLI and the UI on the same cluster at the same time; a lock file in
`.deploy/` stops two UI jobs, not a UI job and a CLI run.

## Troubleshooting

| Symptom | Check |
|---|---|
| "Open the URL printed in the container log" | Use the full `?token=` URL from `docker logs aif`. A restart creates a new token. |
| Page does not load, or "421/403" | Open it as `127.0.0.1` or `localhost`. Other host names are blocked; add them to `WEBUI_ALLOWED_HOSTS` only if you know why. |
| Permission denied on `/opt/aif/clusters` | The host folder must be writable by UID 1000 (see [Run](#run)). |
| "A job is already running" | One job per cluster. Open the job from the cluster page, or wait. A stale lock is in `clusters/<name>/.deploy/webui.lock`. |
| Plan fails on credentials | Re-enter them on the account profile page. |
| State lock error after a stop | Make sure no job runs, then follow the Terraform message to unlock. |
| Container exits at start | `docker logs aif`. |
