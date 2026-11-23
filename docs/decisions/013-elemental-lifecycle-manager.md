# 013 - Elemental Lifecycle Manager component

## Status
Accepted. User guide: [Elemental Lifecycle Manager](../lifecycle-manager.md).

## Context
Elemental Lifecycle Manager (LCM) upgrades the OS, RKE2 and the Helm charts of
a running cluster from one `Release` resource. It needs cert-manager and
System Upgrade Controller (SUC). Rancher provides SUC in `cattle-system`.

Facts that shape the choice:
- Charts in `release.yaml` are resolved from the release manifest; the helm
  list of the Elemental config waits up to 900 s per chart
  ([ADR 001](001-elemental-config-rationale.md)).
- The default `core_platform_override` flattens the release manifest, which
  drops the charts of the core platform manifest, LCM included.
- The core platform manifest for AIF 2.4.0 lists LCM 0.1.2 and its
  dependencies, including SUC. The elemental3 resolver gives the core manifest
  precedence over added charts. LCM 0.2.0 (beta) does not manage SUC when
  Rancher exists.
- With the beta override, the nodes run an OS and an RKE2 version that no
  published release matches.

## Decision
- **New component `elemental-lifecycle-manager`**, opt-in, not in the default
  list.
- **Delivery through `release.yaml`**, not `*-priority.yaml` manifests
  ([ADR 010](010-security-observability.md)). The chart is resolved from the
  manifest and cert-manager comes in as a dependency, so the usual path fits.
- **Charts 0.2.0 beta** (`elemental-lifecycle-manager-crds` and
  `elemental-lifecycle-manager`, `oci://registry.suse.com/beta/uc/charts`,
  namespace `elemental-system`). The pins are in
  `modules/elemental-config/lifecycle-manager.tf`.
- **Injection into the flattened manifest.** With the default override, the
  tool adds the LCM charts to the flattened release manifest
  (`beta-overrides.tf`), listed in [workarounds](../workarounds.md).
- **SUC only without Rancher.** With `rancher` enabled, Rancher
  provides SUC. Otherwise the tool adds the `system-upgrade-controller` chart
  109.0.2 from `https://charts.rancher.io/`.
- **cert-manager is required** and pulled in automatically. Webhook TLS uses
  the self-signed certificates of the chart default.
- **No `Release` resource is created.** Which release a cluster should move to
  depends on what its nodes run; with the beta override no published release
  matches. The guide shows how to apply one by hand and how to inspect the
  target first.
- **Drift is documented, not handled.** Terraform owns day 0 (image and
  nodes), LCM owns in-place day-2 upgrades.

## Consequences
- After an LCM upgrade, the state describes the old image. A later change of
  `aif_release` or any `build_hash` input rebuilds the image and replaces all
  nodes. `deploy.sh` shows replacements before it confirms.
- Adding or removing the component changes `build_hash` and replaces nodes.
- With `core_platform_override = null`, the core manifest wins: LCM 0.1.2 is
  installed and SUC is installed even with Rancher.
- The beta chart pin is one more item to remove once a GA core platform
  manifest ships LCM 0.2.0 or later.
- Private chart registries need credentials on `HelmChart` resources
  (upstream issue #28).

## Alternatives
- **Priority manifests** (like ADR 010): no manifest resolution, but they
  duplicate cert-manager and SUC handling that the release path already does.
- **LCM 0.1.2 from the core manifest only**: needs `core_platform_override =
  null`, which the GA `elemental3ctl` 3.0.x cannot replace yet.
- **Create the `Release` in Terraform**: would move nodes to a release that
  does not match them under the beta override.
- **Detect and block drift in `deploy.sh`**: the state has no record of an LCM
  upgrade; a check would need cluster access during plan.
