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

## SUSE Security and SUSE Observability

The `security-*` and `observability-*` components
([ADR 010](decisions/010-security-observability.md)) add these secrets to state
and to the image (`-priority` manifests, setup Jobs and Secrets):

- The per-cluster CA key, the ingress certificate key and, with
  `security-management`, the NeuVector Manager backend key. The ingress
  certificate is valid 820 days and is re-issued by an apply within 30 days of
  expiry (an image rebuild); the backend certificate is valid 5 years and the CA
  10, without renewal.
- The NeuVector admin password and the federation join token. The join token is
  shared across clusters and also sits in `common-all.tfvars`.
- The Observability admin password, the license key and the bootstrap token.
  The bootstrap token persists in the server `HelmChart` values (it is the
  `stackstate-admin` service token); the setup Jobs delete only their own copy.
- The Application Collection credentials (as for other AppCo charts).

Federation endpoints use the NeuVector controller's self-signed certificate, so
the clusters do not verify each other's certificate: trust comes from the join
token, and exposure is limited by `ingress_cidrs` on both clusters (federation
shares port 443 through SNI passthrough). Other clients (setup Jobs, agent,
collector) verify the server against the CA passed in `observability_ca_pem`.
Browsers do not trust the per-cluster CA until you import it.

### Trusting the cluster CA in the browser

The SUSE Security and SUSE Observability UIs, and the Rancher Observability
extension (it calls the Observability API from the browser), need the cluster
CA trusted. The CA is public; its key never leaves Terraform state.

```bash
# the same CA in both outputs; use security when observability-server is not enabled
terraform -chdir=<cluster-dir> output -json observability | jq -r .ca_pem > aif-ca.crt
# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain aif-ca.crt
# openSUSE / SLES
sudo cp aif-ca.crt /etc/pki/trust/anchors/ && sudo update-ca-certificates
```

Firefox keeps its own store: Settings, Privacy & Security, Certificates, View
Certificates, Authorities, Import. Rancher itself uses its own self-signed
certificate (accept it once), not this CA.

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
- Creating and protecting the SSH key pair you list in `ssh_authorized_keys`:
  [ssh-keys.md](ssh-keys.md).

## Network exposure

- SSH reaches the jumphost from `admin_cidrs` only; nodes are reached through
  it with `ProxyJump`. Node public IPs (`control_plane_public_ip`, pool
  `public_ip`) are off by default where the platform allows it.
- exoscale: every node has a public IPv4 and both settings must be `true`
  (load balancer direct return, metadata service, no managed NAT;
  [limitations](providers/exoscale.md#limitations)). Security groups are the
  only filter: worker and GPU nodes have no inbound rules, control planes admit
  only the load balancer ports, no node admits SSH from outside, and private
  network traffic is not filtered.
- Kubernetes API (6443): the public listener admits `api_cidrs`, default
  `0.0.0.0/0`, so by default the API is protected by its certificates and
  tokens alone. Narrow it to keep the API off the internet.
- Supervisor (9345, node join): on aws only the internal load balancer serves
  it. On vultr the API load balancer admits it from the NAT gateway and the
  public addresses of agent nodes. On evroc it is open to any source: the load
  balancer has a public address only and nodes without a public IP join from
  egress addresses the platform does not disclose. On exoscale the control plane
  security group admits it from the control plane and agent security groups
  (nodes join from their public IPs) and from the managed
  `public-nlb-healthcheck-sources` group. Joining requires TLS and the join
  token.
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
