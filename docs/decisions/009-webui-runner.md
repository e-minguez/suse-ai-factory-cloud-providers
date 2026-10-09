# 009 - Web UI runner

## Status
Accepted. The web UI is alpha (version in `tools/webui/VERSION`, currently
`alpha-0.0.2`): interfaces and the volume layout may change between releases.

## Context
Deploying needs Terraform, the provider plugins, `jq`, `ssh`, `openssl` and
this repository. Some users have no such toolchain and prefer a form to
editing `terraform.tfvars`. A UI must still run the same `deploy.sh` flow, so
the CLI and the UI stay equivalent.

## Decision
`tools/webui` is a Go web server that runs in a container on the user's
workstation. It edits tfvars and starts `tools/multicluster/cluster.sh`, which
runs `examples/<p>/deploy.sh` and Terraform. It adds no deploy logic of its own.

Rejected:
- Terraform in the browser. Provider plugins are separate gRPC processes and
  there is no WebAssembly build of them. Cloud APIs do not send CORS headers
  for browser origins, and a deploy needs SSH to the jumphost.
- A hosted multi-tenant service. It would hold cloud credentials and Terraform
  state of its users, which are the most sensitive data of a deployment.

### Persistence
Everything lives on the mounted volume `/opt/aif/clusters`, with the same
layout as `cluster.sh` (tfvars layers, `<name>/`, state, `.deploy/logs`).
Provider credentials are stored there too (`common-<p>.tfvars`, `.aws/`,
`.home/.evroc/config.yaml`), because a destroy days later needs them. `HOME` is
`clusters/.home` (mode 700); it also holds the optional SSH private key
`.ssh/id_ed25519` that kubeconfig download and `ssh.sh` need in the container. The CLI and the UI can
use the same folder. Directories are mode 700, files 600.

### Threat model
The runner holds cloud credentials and can create billable resources.
- It binds to `127.0.0.1` on the host (`-p 127.0.0.1:8080:8080`).
- A random token is printed in the container log. `?token=` is compared in
  constant time and exchanged for an HttpOnly, SameSite=Strict cookie.
- A Host allow-list (`WEBUI_ALLOWED_HOSTS`) blocks DNS rebinding.
- Requests other than GET and HEAD must carry a matching `Origin` (or
  `Referer`) and a same-origin `Sec-Fetch-Site`.
- A strict CSP (`script-src 'self'`, no inline scripts, `frame-ancestors
  'none'`), `nosniff`, `Referrer-Policy: same-origin` and `no-store` on dynamic pages.
- The container runs as a non-root user with a read-only root file system
  (`--read-only --tmpfs /tmp`); only `/tmp` and the volume are written. It runs
  with `--init` because the runner is PID 1.
- Secrets are write-only: the UI shows "set" or "not set", never the value.
  Job output and log views pass through a redaction helper.
- The volume is the secret. Back it up like state and put it on an encrypted
  disk ([005](005-state-secrets.md), [security](../security.md#state-is-secret)).

### Event protocol
Parsing human-readable `deploy.sh` output would break on every wording change.
`scripts/lib/tf.sh` and `deploy-common.sh` instead write JSON lines to the file
descriptor in `DEPLOY_EVENTS_FD` (types `start`, `pass_start`, `plan_summary`,
`confirm_request`, `confirm_response`, `resource`, `diagnostic`, `pass_done`,
`done`). Both variables are opt-in; the CLI is unchanged when they are unset.

The UI cannot give `deploy.sh` a TTY and must not pass `--yes`, because the
user has to review the plan first. With `DEPLOY_CONFIRM_FD`, the confirm step
emits `confirm_request` after the plan summary and reads `yes` or `no` from
that descriptor. The UI shows the replacements and destroys and sends the
answer when the user clicks Apply or Abort. `--yes` still skips the step.

### Forms
Fields come from `examples/<p>/variables.tf` (types, defaults, descriptions)
and `tools/webui/ui.yaml` (basic list, groups, managed variables, labels,
widgets). A basic form covers what a first deploy needs; the rest is under
"Advanced settings". Variables managed by the modules (`image_rebuild`,
`cp_initialized`, ...) are never shown. Tests require that every variable
without a default is basic or a credential and that every name in `ui.yaml`
exists. Only changed values are written, so defaults stay with the module.

SSH keys are resolved once, from pasted text, GitHub (`<user>.keys`) or a
generated ed25519 pair, and stored as key strings with a comment naming the
source. They feed the image `build_hash` and `user_data`, so resolving them at
every deploy would change the image when a GitHub account changes keys.
Refreshing is an explicit action that shows the diff and warns that nodes are
replaced.

### Image
Built from the repository root. A BCI golang stage builds `webui` and `cost`
(`CGO_ENABLED=0`). A stage downloads Terraform 1.16.4 (checksum and GPG
verified) and mirrors the provider plugins after `terraform get`, so plugins are
not downloaded at run time and the runtime has no direct registry access. The
mirror holds one version per provider, so the image sets
`TF_CLI_ARGS_init=-upgrade`: a lock file written by an older image or by the CLI
moves to the mirrored versions instead of failing `terraform init`. Go and
the mirror run on the build platform and cross-compile or select the target
platform. The root file system is the bci-micro file system plus the packages
the scripts need (`bash`, `jq`, `openssh-clients`, `openssl`, `curl`, ...),
copied into `FROM scratch`. This keeps the image small with no package manager
or shell tooling beyond what the scripts use. The aws CLI (pinned, GPG verified)
and the evroc CLI (checksum verified; evroc publishes only a `latest` download)
are added so the aws precheck and the leftovers checks work for every provider.

## Consequences
- The UI is a front end for the existing scripts: a deploy started from the
  UI behaves like one from the CLI, and the event output must stay in step
  with `tf.sh`.
- Credentials sit on disk in the volume in clear text, as `terraform.tfvars`
  already does. Losing or sharing the volume exposes the accounts.
- The UI serves one local user. There is no login beyond the token, no roles
  and no remote access; use SSH port forwarding if needed.
- Stopping the container during an apply can leave state locked or partial.
  The runner forwards SIGTERM as SIGINT to children and waits
  (`WEBUI_STOP_TIMEOUT`), so the container is started with `--stop-timeout 600`.
- Provider plugins are pinned at image build time; a new provider version
  needs a new image.
