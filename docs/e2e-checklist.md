# End-to-end checks not yet run

Every other end-to-end check passed on aws, evroc and vultr for `v0.1.0`.
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
check. Not run yet:

- [ ] Grow the control plane (`control_plane_count` 1 → 3) and a worker pool on
      a running cluster; nothing is replaced.
- [ ] `image_id` set to an existing template: no jumphost build, nodes boot.
- [ ] `deploy_nodes = false` builds the image only; a later run with `true`
      bootstraps the control plane in two passes.
- [ ] As a multicluster downstream: `cluster.sh register` with the node
      `egress_ips` in the management `ingress_cidrs`.

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
- [ ] Management + downstream federation: the downstream cluster appears in
      **Multiple Clusters** of the primary, and `admin` there is `fedAdmin`
      (`security-fed-init` succeeds; a later downstream still joins, so the
      primary kept its join token).
- [ ] Downstream agent self-registration: the downstream cluster shows up in
      SUSE Observability (`kubernetes-v2` instance, topology, OTLP data) with
      no cluster list on the server.
- [ ] CronJob recovery: deploy the downstream cluster before the primary (own
      DNS names); `security-fed-join` joins it within ~15 minutes of the
      primary becoming ready.
- [ ] SNI passthrough: the NeuVector controller sends SNI, so the Traefik
      `IngressRouteTCP` on 443 reaches `fed-master`/`fed-managed`; no other
      port is opened. `kubectl -n cattle-neuvector-system get ingressroutetcp
      neuvector-federation` exists (applied by the security-fed-* jobs).
- [ ] aws with sslip.io hostnames from the public NLB address: the address is
      stable across a node replacement and every hostname resolves and serves.
- [ ] aws: the jumphost `user_data` fits the 16 KiB limit with every component
      enabled; record the size.
