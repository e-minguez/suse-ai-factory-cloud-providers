# SUSE AI Factory on Microsoft Azure: example

Single-cluster root for [`modules/azure`](../../modules/azure/README.md): a
virtual network with a public and a private subnet, a NAT gateway, a Standard
load balancer with a static public IP, a jumphost that builds the Elemental
image, the image in an Azure Compute Gallery, and the nodes. `deploy.sh` runs it
in one pass.

**Status:** untested against a real subscription (Step 0 in
`docs/plans/azure.md`). `deploy_nodes = false` stops after the gallery image.

## Prerequisites

- Terraform 1.16.5 or later (or OpenTofu, experimental), `jq`, `curl`, `ssh`.
- An Azure subscription and a login: `az login` and `az account set`, or a
  service principal (`azure_tenant_id`, `azure_client_id`, `azure_client_secret`
  in `../common-azure.tfvars`). The identity needs Contributor on the
  subscription (or on the resource group when `resource_group_name` is set) and
  read access to the subscription's compute and network usages.
- The resource providers `Microsoft.Compute`, `Microsoft.Network` and
  `Microsoft.Storage` registered; azurerm 5 does not register them (the root
  module only declares them).
- Shared key access allowed on storage accounts (the upload SAS tokens are
  signed with the account key); some organisation policies disable it.
- GPU quota for the VM size family in the region: new subscriptions start at
  0 vCPUs. The plan fails with the quota left per family when it is too low.
- Two different `openssl passwd -6` hashes: `root_password_hash` and
  `node_user_password_hash`.
- `ssh_authorized_keys` (at least one, ed25519 or RSA) and `admin_cidrs`.
- Registry credentials: see [Registry credentials](../../README.md#registry-credentials).

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # edit it
./deploy.sh
```

The jumphost builds the image for 30 to 60 minutes; follow it with
`../../scripts/build-logs.sh -C .`. Terraform waits for the upload marker, then
creates the gallery image version (up to two hours), deletes the VHD, and
starts the nodes. The jumphost user is `jumphost_username` (`suse` by default,
`azureuser` when empty).

Existing network: set `vpc_id`, `public_subnet_id` and `private_subnet_id`;
the private subnet needs a NAT gateway with a public IP. Existing resource
group: set `resource_group_name`; the module deletes only a group it created.

VM sizes are Azure names (`Standard_D8s_v5`, `Standard_NC4as_T4_v3`). The
size must support Generation 2 and Premium SSD, and be offered in the zone
(`zones` defaults to the region's zones; a GPU pool in a
zone that has the GPU size sets `zone`).

## End-to-end runbook

Tfvars layering, later wins: `../common-all.tfvars` (admin_cidrs, password
hashes, ssh keys, registry credentials, `aif_release`), `../common-azure.tfvars`
(`azure_*` credentials, `region`), then `terraform.tfvars` (cluster values:
`gpu_pools`, `worker_pools`, `control_plane_count`).

```bash
./deploy.sh                                   # image, nodes and backends in one pass
./deploy.sh --rebuild                         # force a new image
```

Checks, from this directory (the user runs them):

```bash
# 1. Image version exists
terraform output -json image | jq .
az sig image-version list -g "$(terraform output -json provider_details | jq -r .resource_group)" \
  -r "$(terraform output -json provider_details | jq -r .gallery)" -i "$(terraform output -raw cluster_name)-elemental" -o table

# 2. Nodes, spread over zones
terraform output -json nodes | jq 'to_entries[] | {n: .key, z: .value.zone, ip: .value.private_ip}'

# 3. VMs reached Succeeded (the report-ready unit worked)
az vm list -g "$(terraform output -json provider_details | jq -r .resource_group)" --query '[].{n:name,s:provisioningState}' -o table

# 4. Kubeconfig and Ready nodes
../../scripts/kubeconfig.sh -C . --wait -o ~/.kube/azure.yaml
kubectl --kubeconfig ~/.kube/azure.yaml get nodes -o wide

# 5. Load balancer hairpin: from a control plane, the frontend answers
../../scripts/ssh.sh -C . <control-plane-node>
#    curl -ks https://<api_vip>:6443/version; sudo-less check: su -; nft list table ip azure-lb-hairpin
#    The table redirects 6443 and 9345 only. Open (Step 0.6): 443 from a pod on a
#    control plane (kubectl run --overrides with nodeName=<control-plane>, then
#    curl -ks https://<rancher_hostname>/ping), with and without the timer.

# 6. GPU visible
kubectl --kubeconfig ~/.kube/azure.yaml run smi --rm -it --restart=Never \
  --image=nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 \
  --overrides='{"spec":{"containers":[{"name":"smi","image":"nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":1}}}]}}'

# 7. Rancher
terraform output -raw rancher_url
terraform output -raw rancher_bootstrap_password

# 8. SSH through the jumphost
../../scripts/ssh.sh -C . jumphost
../../scripts/ssh.sh -C . <node>
```
