# End-to-end checks not yet run

Every other end-to-end check passed on aws, evroc and vultr for `v0.1.0`, and on oci in its first run (2026-11-16). gcp passed its first deploys (2026-11-23 and 2026-11-24); the open items are below.
Run these from the cluster directory (`examples/<provider>` or
`clusters/<name>`); `make ci` must pass first.

## vultr

- [ ] GPU pool: GPU operator ready, node advertises `nvidia.com/gpu`,
      `nvidia-smi` works in the driver pod. Not run: no GPU availability.
- [ ] Bare metal (`kind = "bare_metal"`): nodes join through the private NIC
      (`write-node-ip.sh` picks the IPv4 inside `vpc_cidr`), all nodes `Ready`.

## evroc

- [ ] After the optional third pass deleted the build disks, a new node
      (raise a pool `count`) boots from the snapshot and joins.

## exoscale

Passed in de-fra-1 (2026-10-07): a deploy in one run with 3 control planes,
workers and a `gpu3.small` GPU pool (Rancher through the load balancer,
local-path volumes, aif-operator, GPU operator, `nvidia-smi` and a CUDA
workload); `deploy.sh --rebuild` (every node replaced, the pool bootstrapped
again, port 80 closed); a second run without changes; destroy and leftover
check. Passed in de-fra-1 (2026-11-17): one control plane and a
`gpurtx6000pro.small` GPU pool (RTX PRO 6000 Blackwell; GPU operator, CUDA
validator and a PyTorch workload, see
[docs/providers/exoscale.md#gpus](providers/exoscale.md#gpus)). Not run yet:

- [ ] Grow the control plane (`control_plane_count` 1 → 3) and a worker pool on
      a running cluster; nothing is replaced.
- [ ] `image_id` set to an existing template: no jumphost build, nodes boot.
- [ ] `deploy_nodes = false` builds the image only; a later run with `true`
      bootstraps the control plane in two passes.
- [ ] As a multicluster downstream: `cluster.sh register` with the node
      `egress_ips` in the management `ingress_cidrs`.

## oci

The first run (2026-11-16, staged in `clusters/oci-e2e`) covered: image
build and import, UEFI boot on E5.Flex and A10, one then three control planes
joining through the NLB, fault-domain spread, A10 pool with `nvidia-smi`,
`deploy_nodes` false then true, `--rebuild` (every node replaced), destroy and
`tools/leftovers/oci.sh`, and a deployment into an existing VCN (`vpc_id`). Still to run (runbook:
[examples/oci/README.md](../examples/oci/README.md)):

- [ ] A worker pool (`worker_pools`).
- [ ] Rancher local-path volume and aif-operator.
- [ ] A plan after `deploy.sh --rebuild` shows no changes.
- [ ] `image_id` set to an existing image: the jumphost is a bastion only, nodes boot.
- [ ] As a multicluster downstream: `cluster.sh register` with the NAT address in the management `ingress_cidrs`.
- [ ] Expired PARs after 24 hours: `oci os preauth-request list --bucket-name <cluster>-build`.

## gcp

[ADR 014](decisions/014-gcp-module.md), [platform notes](providers/gcp.md). The
first deploys (2026-11-23 and 2026-11-24) passed the quotas and org policies,
the image build, `deploy_nodes = false` then `true`, UEFI boot with `gve` and
`nvme` on `n2-standard-4` and `g2-standard-4`, three control planes joining
through the internal load balancer, one control plane with a worker and a GPU
pool, Rancher and the API on sslip.io, MTU and NTP from DHCP, pod MTU 1410, the
GPU operator with the precompiled driver on L4, `nvidia-smi` in a pod, a
local-path volume, aif-operator, two `--rebuild` runs in a row and a destroy
with a clean leftover check ([Verified](providers/gcp.md#verified)). Runbook:
[examples/gcp/README.md](../examples/gcp/README.md). Find a zone with GPU
capacity first: [GPU capacity](providers/gcp.md#gpu-capacity).

- [ ] Image build: a failed build stops the wait at once.
- [ ] A larger `vpc_mtu`.
- [ ] An RTX PRO 6000 GPU pool (needs `GPUS_PER_GPU_FAMILY` quota and capacity).
- [ ] `image_id` set to an existing image: the jumphost is a bastion only.
- [ ] As a multicluster downstream: `cluster.sh register` with the Cloud NAT
      address in the management `ingress_cidrs`.
- [ ] Existing network (`vpc_id`, `subnet_id`, `nat_ips`): the plan checks read
      a live VPC and subnet and reject a subnet of another VPC or region; one
      control plane boots in the subnet behind its Cloud NAT; `egress_ips`
      equals `nat_ips`; Rancher answers; destroy leaves the VPC, subnet, router
      and NAT; `tools/leftovers/gcp.sh <cluster>` does not list them.

## Multicluster

- [ ] Re-running `cluster.sh register <mgmt> <downstream>` skips the already
      registered downstream.
- [ ] `cluster.sh register <mgmt> <second>` adds the second downstream and keeps
      the first.

## SUSE Security and SUSE Observability

[ADR 010](decisions/010-security-observability.md). Not run yet:

- [ ] Single cluster with `observability-server`, `observability-plugin` and
      `security-management`: the Observability UI and the SUSE AI extension
      load, the Rancher Observability extension shows the cluster, NeuVector
      opens in Rancher and at its own hostname, `admin` is `fedAdmin`.
Run on vultr on 2026-10-29 in the [shape 05 test](../catalog/05-platform/vultr/README.md)
(dedicated observability and security clusters, `ingress_domain` on DuckDNS):
federation with three members and `admin` as `fedAdmin` on the primary, remote
agent self-registration (all four clusters in SUSE Observability), the CronJob
recovery (`obs` was deployed before the primary `sec` and joined about
5 minutes after it was ready, after 2 of 6 restarts) and SNI passthrough on 443
(no other port). Still open for this area:

- [ ] aws with sslip.io hostnames from the public NLB address: the address is
      stable across a node replacement and every hostname resolves and serves.
- [ ] aws: the jumphost `user_data` fits the 16 KiB limit with every component
      enabled; record the size.
