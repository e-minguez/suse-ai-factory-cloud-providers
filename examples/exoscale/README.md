# SUSE AI Factory on Exoscale: example

Single-cluster root for [`modules/exoscale`](../../modules/exoscale/README.md): a
jumphost that builds the elemental image and registers it as a template, the
control planes as an instance pool behind a network load balancer, and optional
GPU and worker pools, in one zone. `deploy.sh` runs it in two passes. Platform
notes: [`docs/providers/exoscale.md`](../../docs/providers/exoscale.md).

**Before you start:** every node gets a public IPv4, filtered by security
groups only, and the cluster runs in a single zone. Exoscale's load balancer,
metadata service and missing NAT gateway leave no alternative today:
[Limitations](../../docs/providers/exoscale.md#limitations).
`control_plane_public_ip` and the pools' `public_ip` default to `true` here;
`false` fails the plan.

## Prerequisites

- Terraform 1.16.4 or later, `jq`, `curl`, `openssl`, `ssh`.
- An Exoscale API key and secret (`exoscale_api_key`, `exoscale_api_secret`,
  for example in `../common-exoscale.tfvars`) bound to an IAM role that allows
  the Compute service: see [API key](#api-key). Terraform passes them to the
  provider and the signed plan-time checks.
- Two different `openssl passwd -6` hashes: `root_password_hash` and
  `node_user_password_hash`.
- `ssh_authorized_keys` (at least one) and `admin_cidrs` (your IP or VPN range).
- The machine running `deploy.sh` inside `api_cidrs`: pass 1 waits for the
  Kubernetes API through the load balancer.
- Registry credentials: `appco_username`/`appco_password` with
  `local-path-provisioner` (default) or `suse-storage`; the others are optional.
  See [Registry credentials](../../README.md#registry-credentials).
- GPU pools: a GPU quota for the family (0 by default; ask Exoscale support).

## API key

Exoscale API keys are bound to an IAM role; the predefined roles are Owner and
Billing. Owner can also manage IAM, and the key ends up in the Terraform state,
so create a role limited to the Compute service, which covers everything the
module uses (instances, instance pools, load balancer, private network,
security groups, anti-affinity groups, templates, quotas):

```json
{
  "default-service-strategy": "deny",
  "services": {
    "compute": { "type": "allow" }
  }
}
```

Portal: **IAM → Roles → Add**, name it (for example `ai-factory-deploy`) and
paste the policy in the JSON editor; then **IAM → Keys → Add** with that role.
The secret is shown once. With the `exo` CLI, using a key that may manage IAM:

```bash
exo iam role create ai-factory-deploy --policy - <<'EOF'
{"default-service-strategy": "deny", "services": {"compute": {"type": "allow"}}}
EOF
exo iam api-key create ai-factory-deploy ai-factory-deploy
```

A rule such as
`{"action": "deny", "expression": "timestamp(identity.created) < timestamp(now) - duration('72h')"}`
before an `allow` rule (with `"type": "rules"`) makes the key expire; leave
enough time for the destroy. Delete the key and the role once the cluster is
gone. Policy reference: [IAM policy examples](https://community.exoscale.com/product/security/iam/how-to/policy-examples/).

## Quickstart

```bash
# Shared values (repo root, or examples/): every provider declares these.
cp ../../common-all.tfvars.example ../../common-all.tfvars   # edit

# Exoscale-only values, optional: ../common-exoscale.tfvars (exoscale_api_key, exoscale_api_secret, region)

cd examples/exoscale
cp terraform.tfvars.example terraform.tfvars                 # edit REPLACE_WITH_*
./deploy.sh
```

Var files, later wins: `../../common-all.tfvars`, `../common-all.tfvars`,
`../common-exoscale.tfvars`, `terraform.tfvars`.

`deploy.sh [--rebuild] [--yes] [-v|-q] [--destroy] [-- <terraform args>]`:
plan, list replacements and destroys, confirm, apply the saved plan. Logs:
`.deploy/logs/<ts>/`.

- Pass 1 "Bootstrap control plane": network, security groups, load balancer,
  jumphost, image build, template, a control plane pool with one member that
  initializes the cluster, and the worker and GPU nodes. It ends when the
  Kubernetes API answers through the load balancer. Follow the build with
  `../../scripts/build-logs.sh`.
- Pass 2 "Scale control plane": `deploy.sh` writes `cp_initialized = true` and
  `image_import_port_open = false` to `pass2.auto.tfvars.json`; the pool
  switches to the join configuration, scales to `control_plane_count` and the
  jumphost's tcp/80 rule goes away.
- Later runs see the pool in state and apply once with the pins. A new template
  (`--rebuild`) reopens tcp/80 for the import and closes it in a second pass.
- `deploy.sh` aborts if a plan would create or replace the control plane pool
  of an initialized cluster.

## After the deploy

```bash
../../scripts/kubeconfig.sh -o ~/.kube/exoscale.yaml    # admin credential, mode 600
../../scripts/ssh.sh jumphost                           # the only SSH entry
../../scripts/ssh.sh <node>                             # through the jumphost; then `su -`
../../scripts/build-logs.sh [--host NAME] [--no-follow]
terraform output nodes
terraform output -raw rancher_bootstrap_password
```

Control plane names are `<cluster_name>-cp-<pool id>-<random>`; take them from
`terraform output nodes`.

## Troubleshooting

| Symptom | Cause and action |
|---|---|
| Plan fails with "Instance types not usable in zone" | Type not offered there, or not activated for the organization (GPU and large types need Exoscale support). |
| Plan fails with "Quota too low" | Ask Exoscale support for more; GPU families start at 0. Right after a destroy, the usage can still count the deleted instances for a few minutes: wait and plan again ([quota notes](../../docs/providers/exoscale.md#quota-and-availability)). |
| Pass 1 waits for the Kubernetes API and times out | This machine is not in `api_cidrs`, or the first member failed. Check it through the jumphost (its address is in the portal while outputs are not written yet): `journalctl -b -u node-hostname -u wait-privnet -u write-node-ip -u rke2-server`. |
| Waiting for the image never ends | Follow `../../scripts/build-logs.sh`; on the jumphost, `grep qcow2 /var/log/elemental-factory.log` shows the fetcher's requests. |
| Template registration fails "Invalid QCOW image" | The image is not qcow2 or its virtual size is outside 10-1000 GiB; check the `deliver` step in the build log. |
| A node has no `private_ip` in `terraform output nodes` | The private network lists no lease for it; check the member in the portal. |

## Destroying

```bash
./deploy.sh --destroy
```

`deploy.sh` removes `pass2.auto.tfvars.json`, so the next deploy starts from
pass 1, and prints the read-only leftover check:

```bash
export EXOSCALE_API_KEY=... EXOSCALE_API_SECRET=...
../../tools/leftovers/exoscale.sh <cluster_name> [--region <zone>]
```

Expect `0 live`. It lists instances, the instance pool, the load balancer, the
private network (by label), the security groups, the anti-affinity group and
templates (by name); it deletes nothing.
