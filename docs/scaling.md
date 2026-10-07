# Scaling a cluster

A cluster has three node kinds, all joining through the API load balancer:

| Kind | Variable | RKE2 role | `nodes[*].role` | Hostname |
|---|---|---|---|---|
| Control plane | `control_plane_count` | server | `control_plane` | `<cluster_name>-cp-NN` (exoscale: `<cluster_name>-cp-<pool id>-<random>`) |
| Worker | `worker_pools` | agent | `worker` | `<cluster_name>-<pool>-NN` |
| GPU worker | `gpu_pools` | agent | `gpu` | `<cluster_name>-<pool>-NN` |

Per-node Ignition and addresses do not depend on how many nodes exist, so
scaling out only creates the new nodes: existing nodes, the image and
`build_hash` stay as they are. Every change goes through
`examples/<provider>/deploy.sh`, which shows replacements and destroys before
asking for confirmation. Nothing should be replaced when only counts or pools
are added; stop if the plan says otherwise.

## Control plane

Set `control_plane_count` to the next odd number (1 → 3 → 5) and re-run
`deploy.sh`. The new servers join the existing etcd cluster.

- Even counts fail at plan (etcd quorum).
- Shrinking is not supported: it removes etcd members without draining them.
- exoscale: the control planes are one instance pool, so a count change
  scales the pool. On a shrink the pool removes the oldest member first and
  its etcd member stays behind (`kubectl delete node <name>` removes it).

## Worker and GPU pools

`worker_pools` and `gpu_pools` share one schema (`instance_type`, `count`,
`disk_size_gb`, `zone`, `public_ip`, `kind`, `placement`; which fields apply is
provider-specific, see `docs/providers/<provider>.md`). Keys are pool names and
must differ between the two maps, because both become hostnames.

```hcl
worker_pools = {
  general = { instance_type = "...", count = 3 }
}
gpu_pools = {
  gpu = { instance_type = "...", count = 2 }
}
```

- **Grow a pool:** raise its `count`. New nodes take the next `NN`; existing
  hostnames do not change.
- **Add a pool:** add a key. Pools are independent, so this does not touch
  other pools.
- **Availability:** each provider checks at plan that the instance types exist
  and can be served (aws: offered in the zone; evroc: flavor offered, compute
  and public IP quota; vultr: plan in stock; exoscale: type offered and
  available to the organization, instance, load balancer and GPU quota). A failing check stops the plan
  before anything is created. Account quotas the provider does not expose are
  not checked; see `docs/providers/<provider>.md`.
- **Shrink a pool or remove it:** Terraform destroys the highest-numbered
  nodes (or the whole pool) without draining them. Drain and delete them from
  Kubernetes first (`kubectl drain`, `kubectl delete node`), and with
  `suse-storage` make sure no volume has its only healthy replica there.
- Changing a pool's `instance_type` replaces or resizes its nodes, depending on
  the provider; check the `deploy.sh` plan.

## Storage

- `local-path-provisioner`: every node gets the data directory, so new nodes
  need nothing. Volumes stay on the node of their pod and are lost with it.
- `suse-storage`: disks are created on nodes whose role or pool is in
  `suse_storage_nodes` (default `["control_plane"]`; e.g.
  `["control_plane", "storage"]` adds the `storage` pool), via the RKE2 node label
  `node.longhorn.io/create-default-disk=true` written into each node's
  Ignition. Plan fails with fewer than three such nodes.
  - Scaling out a role or pool listed in `suse_storage_nodes` adds disks
    automatically.
  - Changing `suse_storage_nodes` reaches new nodes only. Ignition runs on
    first boot and RKE2 applies `node-label` when a node registers, so node
    resources ignore user_data changes instead of replacing nodes. Label
    existing nodes by hand:
    `kubectl label node <node> node.longhorn.io/create-default-disk=true`
    (`...-` removes it, after evicting its replicas in Longhorn).
