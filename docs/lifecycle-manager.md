# Elemental Lifecycle Manager

Optional component `elemental-lifecycle-manager` (LCM). It installs the
[Elemental Lifecycle Manager](https://github.com/SUSE/elemental-lifecycle-manager)
controller, which upgrades a running cluster in place. Design reasons:
[ADR 013](decisions/013-elemental-lifecycle-manager.md).

Status: alpha. The charts are 0.2.0 **beta** builds from
`oci://registry.suse.com/beta/uc/charts`, and this repo is a community project,
not an official SUSE product. Expect changes.

## What LCM does

LCM upgrades an environment built with SUSE Elemental in three steps: the OS
(SLES), then RKE2, then the Helm charts. One `Release` custom resource
triggers the whole upgrade.

- LCM pulls the release manifest as an OCI image `<registry>:<version>` that
  contains `release_manifest.yaml`. SUSE AI Factory publishes it as
  `ghcr.io/suse/aif-uc-release-manifest`, with tags such as `2.3.1` and `2.4.0`.
- OS and RKE2 upgrades run through System Upgrade Controller (SUC) plans:
  control plane nodes first, then workers, one node at a time. A node is
  drained when its group has more than one node.
- Helm upgrades edit the `HelmChart` resources (helm-controller). Charts that
  are in the manifest but not on the cluster are skipped.
- One `Release` per cluster. No downgrades. No new upgrade while one runs.

Upstream documentation:
[workflow](https://github.com/SUSE/elemental-lifecycle-manager/blob/main/docs/workflow.md),
[Release API](https://github.com/SUSE/elemental-lifecycle-manager/blob/main/docs/release-api.md),
[monitor and troubleshoot](https://github.com/SUSE/elemental-lifecycle-manager/blob/main/docs/monitor-and-troubleshoot.md),
[chart reference](https://github.com/SUSE/elemental-lifecycle-manager/blob/main/docs/helm-chart-ref.md).

## Enable

The component is not in the default list. Add it to `components`:

```hcl
components = [
  "rancher",
  "gpu-operator",
  "local-path-provisioner",
  "aif-operator",
  "elemental-lifecycle-manager",
]
```

`components` is an image input: changing it on an existing cluster builds a
new image and replaces every node.

## What gets installed

- Charts `elemental-lifecycle-manager-crds` and `elemental-lifecycle-manager`,
  version 0.2.0 (beta), from `oci://registry.suse.com/beta/uc/charts`, in the
  namespace `elemental-system`. They are installed through `release.yaml`, like
  the other charts.
- cert-manager, pulled in as a dependency. The webhook uses self-signed
  certificates from cert-manager (chart default).
- System Upgrade Controller in `cattle-system`. With the `rancher` component,
  Rancher provides it and nothing is added. Without Rancher, the tool adds the
  `system-upgrade-controller` chart 109.0.2 from `https://charts.rancher.io/`.

The version pins are in `modules/elemental-config/lifecycle-manager.tf`, the
single place to bump.

## Verify

Fetch the kubeconfig with `scripts/kubeconfig.sh` (never run automatically;
see its `--help`), then:

```bash
kubectl -n elemental-system get pods,helmcharts
kubectl get crd releases.lifecycle.suse.com
```

All pods are `Running` or `Completed` and the CRD exists. Without Rancher,
also check `kubectl -n cattle-system get pods` for the SUC pod.

## Trigger an upgrade

The tool does not create a `Release`. Apply one by hand when you want to
upgrade:

```yaml
apiVersion: lifecycle.suse.com/v1alpha1
kind: Release
metadata:
  name: aif
  namespace: elemental-system
spec:
  version: 2.4.0
  registry: ghcr.io/suse/aif-uc-release-manifest
  # disableDrain: true
  # componentConfiguration:
  #   helm: ...
```

**Inspect the target first.** With the default `core_platform_override`
(a beta workaround, see [workarounds](workarounds.md)), the nodes do not match
any published release. For AIF 2.4.0 they run OS
`registry.suse.com/beta/uc/base-os-kernel-default:16.1-73.2` and RKE2
`v1.35.6+rke2r1`. A `Release` for 2.4.0 would move the OS to `16.0-4.49` (GA,
an older line) and RKE2 to `v1.36.4+rke2r1`. Read the target manifest and its
core platform image, and compare them with the running nodes:

```bash
crane export ghcr.io/suse/aif-uc-release-manifest:2.4.0 - | tar -xO release_manifest.yaml
kubectl get nodes -o wide
```

Do this on a throwaway cluster first.

## Monitor

```bash
kubectl get release -n elemental-system -o yaml
kubectl -n cattle-system get plans
kubectl -n cattle-system get jobs
```

The `Release` status shows the current step. Plans and jobs show the node
upgrades. Upstream has a troubleshooting guide (link above).

## Terraform and LCM

Terraform owns day 0: the image build and the nodes. LCM owns in-place day-2
upgrades. After an LCM upgrade, the Terraform state still describes the old
image. If you then change `aif_release`, or anything else that feeds
`build_hash`, Terraform builds a new image and **replaces all nodes**.
`deploy.sh` lists replacements before it asks for confirmation: read that list
before you accept. To move a cluster to a new release, use either an LCM
`Release` or a rebuild, not both.

## Limitations

- Beta charts: 0.2.0 is not a GA release.
- Charts from private registries need credentials on their `HelmChart`
  resources. Upstream issue:
  [SUSE/elemental-lifecycle-manager#28](https://github.com/SUSE/elemental-lifecycle-manager/issues/28).
- With `core_platform_override = null`, the core platform manifest
  (`registry.suse.com/elemental/rke2/rke2-manifest:1.36.4-13.1` for AIF 2.4.0)
  already lists LCM 0.1.2 and its dependencies, including SUC. The core
  manifest has precedence, so 0.1.2 is installed instead of 0.2.0, and SUC is
  installed even with Rancher. LCM 0.2.0 does not manage SUC when Rancher
  exists.
- No `Release` is created for you, and there is no downgrade path.

## Removal

Removing `elemental-lifecycle-manager` from `components` changes
`build_hash`: the next apply rebuilds the image and replaces all nodes. The new image no
longer deploys LCM.
