# 03: Management and GPU downstream on Vultr

Shape overview: [../README.md](../README.md). Status: covered on 2026-10-29 by the [shape 05 test run](../../05-platform/vultr/README.md), not run on its own: `register --bootstrap`, the Rancher import of the GPU cluster and AI Factory targeting it were checked; the GPU cluster used Longhorn instead of local-path.
Two clusters from `examples/vultr`, run with `tools/multicluster/cluster.sh`.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-vultr.tfvars`
  with the credentials, the region and `admin_cidrs`.
- Application Collection credentials (`appco_username`, `appco_password`): both
  clusters need them through `local-path-provisioner`.
- Stock of the GPU plan in your region. The plan `vcg-a40-24c-120g-48vram` is a
  passthrough plan with a verified driver. Plan fails when it is not in stock.
  Check one region:

  ```bash
  curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
    "https://api.vultr.com/v2/regions/$REGION/availability" \
    | jq -r '.available_plans[]' | grep -E '^vcg-'
  ```

  Check all regions: `VULTR_API_KEY=... tools/vultr/passthrough-stock.sh`.
  Put both clusters in a region that has the plan.
- Go, for the cost estimate.
- Network: all clusters use the default `vpc_cidr` of `examples/vultr`. See [one VPC range for all clusters](../../README.md#vultr-one-vpc-range-for-all-clusters).

## Steps

Run from the repo root.

1. Create and edit the management cluster.

   ```bash
   tools/multicluster/cluster.sh new --empty vultr mgmt
   cp catalog/03-mgmt-gpu/vultr/mgmt.tfvars.example clusters/mgmt/terraform.tfvars
   $EDITOR clusters/mgmt/terraform.tfvars
   tools/multicluster/cluster.sh cost mgmt
   tools/multicluster/cluster.sh deploy mgmt
   ```

   `cp` onto the existing file keeps its mode 600.

2. Create and edit the GPU cluster.

   ```bash
   tools/multicluster/cluster.sh new --empty vultr gpu
   cp catalog/03-mgmt-gpu/vultr/gpu.tfvars.example clusters/gpu/terraform.tfvars
   $EDITOR clusters/gpu/terraform.tfvars
   tools/multicluster/cluster.sh cost gpu
   tools/multicluster/cluster.sh deploy gpu
   ```

   Each deploy runs two passes and takes tens of minutes. Follow the image build
   with `clusters/<name>/build-logs.sh`.

3. Import `gpu` into the management Rancher.

   ```bash
   tools/multicluster/cluster.sh register --bootstrap mgmt gpu
   ```

   `--bootstrap` is needed once, because a new Rancher has no API token yet. It
   logs in with the bootstrap password, creates an admin token, and replaces the
   admin password with a random one. The token is kept in
   `clusters/.register/mgmt/`. That directory is a secret.

   Read the new admin password from the repo root:

   ```bash
   TF_DATA_DIR="$PWD/clusters/.register/mgmt/.terraform" \
     terraform -chdir=tools/multicluster/register output -raw admin_password
   ```

   `register` checks that the `mgmt` `ingress_cidrs` include the `gpu` egress
   addresses (the NAT gateway). The default `0.0.0.0/0` passes.

## Verify

```bash
tools/multicluster/cluster.sh list
terraform -chdir=clusters/mgmt output -raw rancher_url
```

- Open the Rancher URL and log in as `admin`. The cluster `aif-gpu` is
  listed and `Active`. `register` imports it under its `cluster_name`.
- On `gpu`, check the GPU. Fetch the kubeconfig to a file, with mode 600:

  ```bash
  mkdir -p ~/.kube
  clusters/gpu/kubeconfig.sh --wait -o ~/.kube/aif-gpu.yaml
  KUBECONFIG=~/.kube/aif-gpu.yaml kubectl get nodes
  KUBECONFIG=~/.kube/aif-gpu.yaml kubectl get pods -n gpu-operator
  ```

  The GPU node reports `nvidia.com/gpu` in its capacity once the operator is
  ready.

## Cost

Run `tools/multicluster/cluster.sh cost mgmt` and `... cost gpu` before you
deploy. The estimate is not a quote. Each cluster has these billed objects:

- the jumphost, the control-plane nodes and the pool nodes
- an API load balancer and an ingress load balancer
- a NAT gateway
- the image snapshot

The GPU plan is the main cost. The nodes have no public IP, so the GPU nodes
reach the internet through the NAT gateway.

## Destroy

Destroy the downstream cluster first, then the management cluster.

```bash
tools/multicluster/cluster.sh destroy gpu
tools/multicluster/cluster.sh destroy mgmt
```

- Deleting `gpu` does not remove its entry in Rancher: the imported cluster
  stays, and Rancher reports it as unreachable. Delete it in the Rancher UI, then remove `gpu` from
  `clusters/.register/mgmt/downstream.list` so that a later `register` does not
  use it again.
- When `mgmt` is destroyed, `clusters/.register/mgmt/` is stale. Delete the
  directory before you deploy a new `mgmt`, and use `--bootstrap` again.
- After a successful destroy, `deploy.sh` prints the leftovers check. It does
  not run it. Run it yourself after you export the API key:

  ```bash
  export VULTR_API_KEY=...
  tools/leftovers/vultr.sh aif-gpu
  tools/leftovers/vultr.sh aif-mgmt
  ```

  It deletes nothing. Expect `0 live, 0 unknown`.
- To reuse the names `gpu` or `mgmt`, remove the old directories first:
  `cluster.sh new` refuses an existing one (`rm -rf clusters/gpu clusters/mgmt`).

## Troubleshooting

- Plan fails with "Plans not available in region": no stock for a plan, or an
  invalid `vultr_api_key`. Check stock as above.
- `register` stops at the CIDR check: add the printed `gpu` egress addresses to
  `ingress_cidrs` of `mgmt`, or pass `--skip-cidr-check` when you know the path
  is open.
- A node never joins: see the table in
  [examples/vultr/README.md#troubleshooting](../../../examples/vultr/README.md#troubleshooting).
- Platform notes (GPU plans, driver, network, stock):
  [docs/providers/vultr.md](../../../docs/providers/vultr.md).
- Register and token handling:
  [tools/multicluster/README.md](../../../tools/multicluster/README.md).
