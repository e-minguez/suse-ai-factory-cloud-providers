# 01: Inference in a box on Harvester

Shape overview: [../README.md](../README.md). Status: not run end to end on Harvester yet.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars`. Harvester values go in `clusters/common-harvester.tfvars`
  (mode 600): optionally `harvester_kubeconfig_path` (else the kubeconfig comes from
  `KUBECONFIG`), `harvester_namespace`, `vpc_id` (`<namespace>/<network>`), `vpc_cidr` (the real subnet
  of that network) and `region` (a label, `"harvester"`). `harvester_kubecontext` is optional. These values
  are not in the cluster file.
- Harvester 1.8 or later with an existing namespace and an existing VM network (`vpc_id`). Creating networks is not part of the module.
- Two free static IPv4 addresses in `vpc_cidr`, outside the DHCP range: `api_vip` and `ingress_vip`. The example uses `.40` and `.41`.
- Harvester downloads the openSUSE Leap cloud image from `buildhost_image_url` unless `jumphost_image` names an existing image in the namespace. The cluster needs outbound access for that download.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- The GPU is a passthrough device on the control plane: `gpu_devices = { cp = ... }` (key `cp` = control planes). Needs the `pcidevices-controller` add-on and the device enabled for passthrough. Verified with an NVIDIA A10; passthrough pins all node memory on the host, so size `control_plane_instance_type` to the free host memory.

## Steps

```bash
tools/multicluster/cluster.sh new --empty harvester box
cp catalog/01-inference-in-a-box/harvester/box.tfvars.example clusters/box/terraform.tfvars   # cp keeps the 600 mode
$EDITOR clusters/box/terraform.tfvars
tools/multicluster/cluster.sh deploy box
```

One pass: the build host builds the image (about 30 minutes or more), Harvester exports it as a node image, then the node boots.
Harvester has no cost estimate, so `cluster.sh cost` does not apply.

## Verify

```bash
mkdir -p ~/.kube
clusters/box/kubeconfig.sh --wait -o ~/.kube/aif-box.yaml
export KUBECONFIG=~/.kube/aif-box.yaml
kubectl get nodes                              # one node, Ready
kubectl get pods -A
terraform -chdir=clusters/box output -raw next_steps
```

## Destroy

```bash
tools/multicluster/cluster.sh destroy box
```

After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/harvester.sh`. It does not run it; run it yourself with your kubeconfig for the Harvester cluster. It deletes nothing.

## Troubleshooting

- Plan fails on `api_vip` or `ingress_vip`: an address is outside `vpc_cidr`, the two are equal, or the address is already in use. The plan does not check DHCP leases; a duplicate address shows up at boot.
- Plan fails on the image or the network: `jumphost_image` or `vpc_id` does not exist in the namespace.
- The node stays Pending: Harvester has no free capacity for 30 vCPU / 240 GiB. The plan does not read host capacity; choose a smaller plan or free a host.
- Platform notes and the first-deploy checklist: [docs/providers/harvester.md](../../../docs/providers/harvester.md).
