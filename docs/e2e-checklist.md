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

## Multicluster

- [ ] Re-running `cluster.sh register <mgmt> <downstream>` skips the already
      registered downstream.
- [ ] `cluster.sh register <mgmt> <second>` adds the second downstream and keeps
      the first.
