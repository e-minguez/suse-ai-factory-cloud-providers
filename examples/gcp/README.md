# SUSE AI Factory on Google Cloud (GCP): example

Single-cluster root for [`modules/gcp`](../../modules/gcp): a custom-mode VPC
with one subnet and a Cloud NAT, an external and an internal passthrough
network load balancer over the control planes, a jumphost that builds the
Elemental image, and the global image created from a snapshot of the disk the
build wrote. `deploy.sh` runs it in one pass.

**Status:** experimental. Deployed with three control planes and an L4 GPU
node; open items are in
[docs/providers/gcp.md](../../docs/providers/gcp.md#still-open).
`deploy_nodes = false` stops after the image.

## Prerequisites

- Terraform 1.16.5 or later (or OpenTofu, experimental), `jq`, `curl`, `ssh`.
- A project with the Compute Engine API enabled, and quota for the machine
  types (GPU quota in the region, `GPUS_ALL_REGIONS`). Set `gcp_project` (the
  project ID) and `region` in `../common-gcp.tfvars`. Quota does not
  guarantee GPU capacity: find a zone with a probe first, see
  [GPU capacity](../../docs/providers/gcp.md#gpu-capacity).
- Application Default Credentials, never tfvars: `gcloud auth
  application-default login`, or `GOOGLE_APPLICATION_CREDENTIALS` pointing at
  a key file. `gcp_impersonate_service_account` makes the provider impersonate
  a service account with them. The identity needs to manage compute, networks,
  disks, images, snapshots and addresses in the project.
- Two different `openssl passwd -6` hashes: `root_password_hash` and
  `node_user_password_hash`.
- `ssh_authorized_keys` (at least one) and `admin_cidrs`.
- Registry credentials: see [Registry credentials](../../README.md#registry-credentials).

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # edit it
./deploy.sh
```

The jumphost builds the image; follow it with `../../scripts/build-logs.sh -C .`.
Terraform reads the build state from guest attributes, then snapshots the build
disk and creates the image.

Machine types are plain names (`n2-standard-4`, `g2-standard-8`); GPUs come
with the type. Zones are full names (`europe-west4-a`). `boot_disk_type`
overrides the per-family boot disk type of the nodes.

`keep_build_artifacts` has no effect on gcp: the build disk and the snapshot
stay until the next build or `./deploy.sh --destroy`.

Existing VPC: set `vpc_id` and `subnet_id` (and `nat_ips`; requirements in
[docs/providers/gcp.md](../../docs/providers/gcp.md#existing-network)).

## End-to-end runbook

Tfvars layering, later wins: `../common-all.tfvars` (admin_cidrs, password
hashes, ssh keys, registry credentials, `aif_release`), `../common-gcp.tfvars`
(`gcp_project`, `region`), then `terraform.tfvars` (cluster values: `gpu_pools`,
`worker_pools`, `control_plane_count`).

```bash
./deploy.sh                                   # image, nodes and backends in one pass
./deploy.sh --rebuild                         # force a new image
```

Checks, from this directory (the user runs them):

```bash
# 1. Image
terraform output -json image | jq .

# 2. Nodes
terraform output -json nodes | jq 'to_entries[] | {n: .key, z: .value.zone, ip: .value.private_ip}'

# 3. Kubeconfig and Ready nodes
../../scripts/kubeconfig.sh -C . --wait -o ~/.kube/gcp.yaml
kubectl --kubeconfig ~/.kube/gcp.yaml get nodes -o wide

# 4. GPU visible
kubectl --kubeconfig ~/.kube/gcp.yaml run smi --rm -it --restart=Never \
  --image=nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 \
  --overrides='{"spec":{"containers":[{"name":"smi","image":"nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":1}}}]}}'

# 5. Rancher
terraform output -raw rancher_url
terraform output -raw rancher_bootstrap_password

# 6. SSH through the jumphost
../../scripts/ssh.sh -C . jumphost
../../scripts/ssh.sh -C . <node>
```
