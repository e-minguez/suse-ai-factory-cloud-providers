# 001 - elemental-config: rendering choices

## Status
Accepted.

## Context
`modules/elemental-config` renders every Elemental, RKE2 and Helm file that
was previously copied into each provider module. The templates used to carry
long comments explaining non-obvious choices; the comments are now short and
link here.

## Decision
- **Roles in per-node Ignition, not in the image.** `cluster.yaml` has no
  `nodes:` list. Elemental then writes its own `runtime.env` with
  `IS_INIT_NODE=true`; per-node Ignition (`node_runtime_ignition`) overwrites
  it with the node's role. The image is independent of the node set, so adding
  a node never rebuilds the image.
- **Canal HelmChartConfig via per-node Ignition (servers only).** RKE2 reads
  `/var/lib/rancher/rke2/server/manifests` at startup. Elemental's own
  `kubernetes/manifests/` is applied only after the API answers, by which time
  the canal chart is installed with its defaults. The chart's values reach the
  DaemonSet through a ConfigMap and no pod-template change follows, so a late
  HelmChartConfig never takes effect (SUSE/elemental#570). Writing the file
  before `rke2-server` starts avoids this. Editing it reaches new nodes only
  (node resources ignore user_data changes) and does not rebuild the image.
- **Image manifests are `*-priority.yaml`.** Elemental's
  `k8s-resource-installer` applies `*-priority.yaml` from `kubernetes/manifests/`
  right after RKE2's core charts, then creates each HelmChart and waits up to
  900 s for its install job, and applies the other manifests last, only when
  every chart job completed. A chart that fails or hangs therefore also drops
  the Traefik HelmChartConfig (the NLB checks on 8080 fail) and the AppCo pull
  secrets (local-path stays in `ImagePullBackOff`). As priority manifests they
  do not depend on any chart. A test keeps every image manifest a priority one.
- **Scripts run through `bash`, live in `/var/lib/elemental`.** The image root
  is read-only while Ignition runs, and a failed write there ends in the
  initrd emergency shell. Files written to `/var/lib/elemental` are labelled
  `var_lib_t`, which SELinux does not let `init_t` execute (`203/EXEC`), so
  the units call `/usr/bin/bash <script>`.
- **`write-node-ip.sh`.** With one NIC RKE2's default node-ip is correct and
  the script writes nothing. With several it picks the IPv4 address inside
  `vpc_cidr`, which the initrd network setup has already configured, and writes
  `99-node-ip.yaml`. It retries for up to 60 s in case the address is not up.
- **`iscsi-prep.sh`.** The `suse-storage` sysext ships `/usr/sbin/iscsid` and
  nothing under `/etc` (no initiator name, no `iscsid.conf`, no enablement).
  Without them Longhorn volumes bind but the consuming pod never attaches
  (`AttachVolume.Attach ... DeadlineExceeded`). The unit seeds `/etc/iscsi` at
  every boot and starts iscsid with `--no-block`, because ordering a blocking
  start inside a unit that iscsid is ordered after would deadlock.
- **`local-path-prep.service`.** `/opt` is read-only in the initrd, so the data
  directory is created at boot with `mkdir -Z`, which applies the
  `container_file_t` label from rke2-selinux.
- **`/home` filesystem entry.** `/home` is a btrfs subvolume that is not mounted
  in the initrd. Declaring it makes Ignition create user homes on the real
  subvolume instead of a directory that is later shadowed.
- **`jsonencode()` for every credential in YAML.** A bare or double-quoted
  scalar breaks on `"`, `\`, `:` or `#`, either failing the parse or silently
  yielding a different string; a JSON string is always a valid YAML scalar.
- **Comment stripping (one pass).** Lines starting with `#` (except `#!`) are
  removed from every rendered file and Ignition payload before hashing and
  before user data. Editing a comment never rebuilds the image, and per-node
  Ignition shrinks (about 5 KB to under 1 KB for a server).
- **`build_hash`.** SHA-256 over the stripped files, the manifest body, the
  image, `core_platform_override`, the effective sysext overrides,
  `extra_build_inputs` and `image_rebuild` when greater than 0. It is the only
  rebuild trigger.
- **Chart dependencies.** The `rancher -> cert-manager` injection is dropped;
  elemental resolves `dependsOn` from the manifest and inserts dependencies
  itself.
- **Release manifest rewrite in Terraform.** The manifest is fetched once at
  plan time, rewritten with `yamldecode`/`yamlencode` when a beta override
  applies, hashed, and shipped as `release_manifest.yaml`. The build host
  builds from exactly the manifest the plan hashed. Without overrides the body
  is shipped unchanged.

## Consequences
Provider modules pass platform differences as inputs (`kernel_cmdline`,
`tls_san`, `canal_iface_regex`, `pod_veth_mtu`, `extra_*`, `nodes`,
`user_data_max_bytes`) and keep only cloud resources and `network/*.sh`.
