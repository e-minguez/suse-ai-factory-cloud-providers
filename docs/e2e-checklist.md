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

A first deploy (de-fra-1, 3 control planes, 1 worker), destroy and leftover
check passed. Not run yet:

- [ ] `deploy.sh --rebuild` on a running cluster: port 80 opens for the import
      and closes again, the pool template updates in place, workers are
      replaced and rejoin.
- [ ] GPU pool: GPU operator ready, node advertises `nvidia.com/gpu`,
      `nvidia-smi` works in the driver pod. Not run: GPU quota 0.
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
