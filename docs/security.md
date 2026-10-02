# Security

## State is secret

Terraform state carries every sensitive input in plaintext: the RKE2 join token
(`random_password.token`, rendered into every node's user_data), the Rancher
bootstrap password, root and node password hashes, and the SUSE, AppCo and
NVIDIA registry credentials rendered into the image config or user_data.
Removing an output does not remove a value from state when a resource attribute
such as `user_data` still carries it.

No provider exposes `rke2_token` as an output. The token stays in state through
user_data by design. Treat state as a credential:

- Use an encrypted remote backend (for example S3 with SSE-KMS, or an
  equivalent for other backends). Use a local, unencrypted state file only for
  a throwaway test.
- Restrict who can read the backend the same way you restrict access to the
  credentials it contains.
- Never commit state, plan files, or the `.terraform/` directory.

`tools/multicluster` keeps register state under `clusters/.register/<mgmt>/`.
With `--bootstrap` it holds a Rancher admin token: treat it the same way.

## Never commit these

`*.tfvars` (including `common-all.tfvars`, `common-<provider>.tfvars`,
`terraform.tfvars` and `pass2.auto.tfvars.json`), `*.tfstate*`, `*.tfplan*`,
`.deploy/` and any `kubeconfig*` file. `.gitignore` at the repo
root covers all of these; `*.tfvars.example` files are the only variable files
meant to be tracked. `.deploy/` logs can contain sensitive values.

## Kubeconfig and SSH

- `scripts/kubeconfig.sh` is never run automatically by `deploy.sh` or any other
  script; `deploy.sh` only prints how to fetch it. It prints the admin
  kubeconfig to stdout by default; `-o FILE` creates the file with mode 600 and
  refuses to overwrite an existing file without `--force`. The kubeconfig is an
  admin credential.
- `scripts/ssh.sh` and the other SSH helpers use a throwaway `ssh_config` and
  `known_hosts` created in `mktemp -d` and removed on exit. The config has a
  `jumphost` host and one host per node with `ProxyJump jumphost`, plus
  `GlobalKnownHostsFile /dev/null`, `StrictHostKeyChecking accept-new` and
  `UpdateHostKeys no`. Host keys are trusted on first contact in each
  invocation, because addresses are recycled across rebuilds and clusters and a
  persistent `known_hosts` collects stale entries. `ssh.sh --config` prints the
  same config for `scp` and `rsync -e`; `--known-hosts FILE` keeps the host keys
  in a file you choose. No host keys are managed by Terraform, nothing is
  written to the operator's `~/.ssh`, and no script uses
  `StrictHostKeyChecking=no`.

## Network exposure

- SSH reaches the jumphost from `admin_cidrs` only; nodes are reached through
  it with `ProxyJump`. Node public IPs (`control_plane_public_ip`, pool
  `public_ip`) are off by default where the platform allows it.
- Kubernetes API (6443): the public listener admits `api_cidrs`, default
  `0.0.0.0/0`, so by default the API is protected by its certificates and
  tokens alone. Narrow it to keep the API off the internet.
- Supervisor (9345, node join): on aws only the internal load balancer serves
  it. On vultr the API load balancer admits it from the NAT gateway and the
  public addresses of agent nodes. On evroc it is open to any source: the load
  balancer has a public address only and nodes without a public IP join from
  egress addresses the platform does not disclose. Joining requires TLS and the
  join token.
- Ingress (80/443, the Rancher UI) admits `ingress_cidrs`, default
  `0.0.0.0/0`. Narrow it for clusters that are not public.
- During an evroc image build, the status relay on the jumphost is readable from
  `admin_cidrs`.

## Node access

The Elemental image has no sudo. Log in as `node_username` and use `su -` for
root. RKE2 writes its kubeconfig group-readable by `node_username`, so tooling
does not need root. `permit_root_ssh` is a debug toggle, off by default; changing
it rebuilds the image.

## Object storage

Instances do not read from S3 or other object storage. The only exception is the
aws jumphost, which uploads the raw image.
