locals {
  # Per node: hostname, role, the Longhorn default-disk label (suse_storage_nodes;
  # per node so it stays out of build_hash) and, on servers, the canal
  # HelmChartConfig, which must sit in RKE2's manifests directory before rke2-server starts.
  node_files = {
    for n in var.nodes : n.hostname => concat(
      [
        { path = "/etc/hostname", mode = 420, content = "${n.hostname}\n" },
        {
          path = "/var/lib/elemental/runtime.env"
          mode = 420
          content = join("", concat(
            ["NODETYPE=${n.type}\n"],
            n.init ? ["IS_INIT_NODE=true\n"] : [],
          ))
        },
      ],
      n.node_ip == null ? [] : [
        { path = "/etc/rancher/rke2/config.yaml.d/99-node-ip.yaml", mode = 420, content = "node-ip: ${n.node_ip}\n" },
      ],
      local.suse_storage_enabled && (contains(var.suse_storage_nodes, coalesce(n.role, n.type == "server" ? "control_plane" : "gpu")) || contains(var.suse_storage_nodes, coalesce(n.pool, "-"))) ? [
        { path = "/etc/rancher/rke2/config.yaml.d/90-longhorn-disk.yaml", mode = 420, content = "node-label:\n  - \"node.longhorn.io/create-default-disk=true\"\n" },
      ] : [],
      n.type != "server" ? [] : [
        { path = "/var/lib/rancher/rke2/server/manifests/canal.yaml", mode = 420, content = local.canal_manifest },
      ],
    )
  }

  # Ignition creates parent directories itself. base64 data URLs avoid the
  # space-as-"+" pitfall of percent-encoding.
  node_runtime_ignition = {
    for hostname, files in local.node_files : hostname => jsonencode({
      ignition = { version = "3.5.0" }
      storage = {
        files = [
          for f in files : {
            path      = f.path
            mode      = f.mode
            overwrite = true
            contents = {
              compression = var.compress_node_files ? "gzip" : ""
              source      = "data:;base64,${var.compress_node_files ? base64gzip(f.content) : base64encode(f.content)}"
            }
          }
        ]
      }
    })
  }

  oversized_nodes = sort([for h, j in local.node_runtime_ignition : "${h} (${length(j)} bytes)" if length(j) > var.user_data_max_bytes])
}
