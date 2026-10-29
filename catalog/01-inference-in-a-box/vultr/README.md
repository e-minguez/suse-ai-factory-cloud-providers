# 01: Inference in a box on Vultr

Shape overview: [../README.md](../README.md). Status: not yet verified end to end.

## Prerequisites

- Shared credentials and settings in `clusters/common-all.tfvars` and `clusters/common-vultr.tfvars`: see [shared prerequisites](../../README.md#shared-prerequisites). Do not put them in the shape file.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- A GPU plan in stock in your region. The example plan `vcg-a40-24c-120g-48vram` is a
  passthrough plan with a verified driver. Plan fails when it is not in stock.
  Check one region:

  ```bash
  curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
    "https://api.vultr.com/v2/regions/$REGION/availability" \
    | jq -r '.available_plans[]' | grep -E '^vcg-'
  ```

  Check all regions: `VULTR_API_KEY=... tools/vultr/passthrough-stock.sh`.
  Stock varies by region. Set `region` in `common-vultr.tfvars` (default `ams`).
- Only passthrough plans work. See [Cloud GPU](../../../docs/providers/vultr.md#cloud-gpu).
- The stock check runs only when the control-plane node is created, its plan changes or the cluster grows; see [plan availability](../../../docs/providers/vultr.md#plan-availability). The GPU plan sits on the single control plane, so later plans of an existing cluster do not fail on stock.
- The example plan has 24 vCPU, 120 GB RAM and 48 GB GPU memory.

## Steps

```bash
tools/multicluster/cluster.sh new --empty vultr box
cp catalog/01-inference-in-a-box/vultr/box.tfvars.example clusters/box/terraform.tfvars   # cp keeps the 600 mode of the existing file
$EDITOR clusters/box/terraform.tfvars
tools/multicluster/cluster.sh cost box     # estimate, needs Go
tools/multicluster/cluster.sh deploy box
```

The deploy runs two passes and builds the image on the jumphost. It takes a while.
`deploy` shows the plan and asks for confirmation.

Variables in `box.tfvars.example`: `cluster_name`, `components`, `control_plane_count`, `control_plane_instance_type`. `ingress_domain` is optional and commented out.

## Verify

```bash
mkdir -p ~/.kube
clusters/box/kubeconfig.sh -o ~/.kube/aif-box.yaml    # admin credential, mode 600, no overwrite without --force
export KUBECONFIG=~/.kube/aif-box.yaml
kubectl get nodes                                  # one node, Ready
kubectl get pods -A                                # all Running or Completed
kubectl describe node | grep nvidia.com/gpu        # GPU capacity 1
terraform -chdir=clusters/box output -raw next_steps   # Rancher URL, ssh, kubeconfig
```

`clusters/box/kubeconfig.sh` prints to stdout without `-o`. The GPU operator can take several minutes to show the GPU.
The ingress load balancer stays unhealthy until Traefik answers; this is expected at first.

## Cost

One GPU plan, one jumphost, two load balancers, a NAT gateway and a snapshot. Run `tools/multicluster/cluster.sh cost box` for an estimate. It is not a quote.

## Destroy

```bash
tools/multicluster/cluster.sh destroy box
```

After a successful destroy, `deploy.sh` prints a leftovers check. It does not run it. Run it yourself after you export the API key:

```bash
export VULTR_API_KEY=...
tools/leftovers/vultr.sh aif-box
```

It deletes nothing. Expect `0 live, 0 unknown`.

To reuse the name `box`, remove the old directory first: `cluster.sh new` refuses an existing one (`rm -rf clusters/box`).

## Troubleshooting

See [examples/vultr/README.md](../../../examples/vultr/README.md#troubleshooting) and [docs/providers/vultr.md](../../../docs/providers/vultr.md).

- "Plans not available in region": no stock, or a missing `vultr_api_key`. Check stock as above.
- GPU not visible: see [GPU driver](../../../docs/providers/vultr.md#gpu-driver).
