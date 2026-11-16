# SUSE AI Factory on Oracle Cloud (OCI): example

Single-cluster root for [`modules/oci`](../../modules/oci): a VCN with a public
and a private subnet, a network load balancer with a reserved public IP, a
jumphost that builds the Elemental image, and the custom image imported from
Object Storage. `deploy.sh` runs it in one pass. Platform notes:
[`docs/providers/oci.md`](../../docs/providers/oci.md).

**Status:** complete; first end-to-end run passed on 2026-11-16 (open items:
"Still open" in the platform notes). `deploy_nodes = false` stops after the imported image.

## Prerequisites

- Terraform 1.16.5 or later (or OpenTofu, experimental), `jq`, `curl`, `ssh`.
- An OCI user with an API key, and a compartment: set `oci_tenancy_ocid`,
  `oci_user_ocid`, `oci_fingerprint`, `oci_private_key_path` and
  `oci_compartment_ocid` in `../common-oci.tfvars`. The user needs to manage
  compute, networking, network load balancers, Object Storage and image
  capability schemas in the compartment, and to read limits in the tenancy.
  Tfvars values are HCL strings and need double quotes. The `key=value` lines
  of `~/.oci/config` do not work as they are: an unquoted OCID fails at plan
  with `Invalid attribute name ... An attribute name is required after a dot`.

  ```hcl
  oci_tenancy_ocid     = "ocid1.tenancy.oc1..<...>"
  oci_user_ocid        = "ocid1.user.oc1..<...>"
  oci_fingerprint      = "aa:bb:...:ff"
  oci_private_key_path = "/home/<you>/.oci/oci_api_key.pem"   # absolute, no ~
  oci_compartment_ocid = "ocid1.compartment.oc1..<...>"
  ```
- Two different `openssl passwd -6` hashes: `root_password_hash` and
  `node_user_password_hash`.
- `ssh_authorized_keys` (at least one) and `admin_cidrs`.
- Registry credentials: see [Registry credentials](../../README.md#registry-credentials).

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # edit it
./deploy.sh
```

The jumphost builds the image for 30 to 60 minutes; follow it with
`../../scripts/build-logs.sh -C .`. Terraform waits for the upload, then OCI
imports the image (up to two hours). Once it is imported, Terraform overwrites
the qcow2 and the marker with one-line objects, so destroy can delete them and
the bucket.

Existing VCN: set `vpc_id`, `public_subnet_id` and `private_subnet_id`
(requirements in
[docs/providers/oci.md](../../docs/providers/oci.md#existing-network)).

Instance types: fixed shapes are a plain name; flex shapes take
`<shape>:<ocpus>x<memory_gb>`, for example `VM.Standard.E5.Flex:4x32`.
Zones are lowercase availability domain names (`ad-1`).

## End-to-end runbook

Tfvars layering, later wins: `../common-all.tfvars` (admin_cidrs, password
hashes, ssh keys, registry credentials, `aif_release`), `../common-oci.tfvars`
(`oci_*` credentials, `region`), then `terraform.tfvars` (cluster values:
`gpu_pools`, `worker_pools`, `control_plane_count`).

```bash
./deploy.sh                                   # image, nodes and backends in one pass
./deploy.sh --rebuild                         # force a new image
```

Checks, from this directory (the user runs them):

```bash
# 1. Image imported and AVAILABLE
terraform output -json image | jq .
oci compute image get --image-id "$(terraform output -json image | jq -r '.ids[]')" --query 'data."lifecycle-state"'

# 2. Nodes, spread over fault domains
terraform output -json nodes | jq 'to_entries[] | {n: .key, z: .value.zone, ip: .value.private_ip}'
terraform output -json provider_details | jq .fault_domains

# 3. Kubeconfig and Ready nodes
../../scripts/kubeconfig.sh -C . --wait -o ~/.kube/oci.yaml
kubectl --kubeconfig ~/.kube/oci.yaml get nodes -o wide

# 4. GPU visible
kubectl --kubeconfig ~/.kube/oci.yaml run smi --rm -it --restart=Never \
  --image=nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 \
  --overrides='{"spec":{"containers":[{"name":"smi","image":"nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":1}}}]}}'

# 5. Rancher
terraform output -raw rancher_url
terraform output -raw rancher_bootstrap_password

# 6. SSH through the jumphost
../../scripts/ssh.sh -C . jumphost
../../scripts/ssh.sh -C . <node>
```
