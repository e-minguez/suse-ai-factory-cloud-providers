# 010 - SUSE Security and SUSE Observability components

## Status
Accepted.

## Context
SUSE AI Factory deployments pair the management cluster with GPU downstream
clusters. SUSE Security (NeuVector) and SUSE Observability (server, agent,
OpenTelemetry Collector, SUSE AI extension, Rancher UI extensions) cover that
layout. Both are plain Helm charts that the AIF release manifest does not
carry. They were first written as standalone manifests with cert-manager,
NodePorts and several manual steps.

Constraints from this repo:
- The Elemental `release.yaml` helm list waits up to 900 s per chart job
  ([ADR 001](001-elemental-config-rationale.md)) and only resolves charts from
  the manifest.
- A cluster must deploy with a plain `terraform apply`, and the image is a
  function of its inputs (`build_hash`).
- `tools/multicluster register` is optional; clusters can run on different
  providers and be deployed in any order.

## Decision
Five new `components` values: `observability-server`, `observability-plugin`,
`observability-agent`, `security-management`, `security-downstream`.
`observability-server` adds `observability-agent` to the effective list, so the
server cluster monitors itself.

Dependencies: all five need Traefik. The server needs a storage component
(`local-path-provisioner` or `suse-storage`), a license key and Application
Collection credentials. The plugin needs `rancher`. Agent and plugin without a
local server need the remote server URL, its CA and the bootstrap token.
`security-management` and `security-downstream` are mutually exclusive;
downstream needs the join token and the primary federation endpoint.

### Delivery
Each component is a `kubernetes/manifests/<name>-priority.yaml` baked into the
image: `HelmChart` resources for the RKE2 Helm controller plus the plain
objects around them (Namespaces, Secrets, ServiceAccounts, Jobs). This avoids
the 900 s gate of the helm list and the manifest-only chart resolution. Optional
extras (OpenTelemetry Operator, `Instrumentation`, demo application) are not in
the image: [`tools/observability`](../../tools/observability/README.md).

### TLS from Terraform
`hashicorp/tls` creates one ECDSA P-256 CA per cluster (10 years), one ECDSA
ingress certificate (820 days) whose SANs are every enabled ingress hostname,
and for `security-management` one RSA 2048 certificate for the NeuVector Manager
backend (5 years, PKCS#1). The ingress certificate stays under 825 days because
Apple platforms reject longer TLS server certificates even under an imported
root. Rendering the certificates as Secrets removes the cert-manager objects, so
there is no CRD ordering between cert-manager and the
`ClusterIssuer`/`Certificate` objects. The CA is known after the server
cluster's apply (output `observability.ca_pem`), so there is no second render
phase inside a cluster; downstream clusters take it as a variable
(`observability_ca_pem`). A later apply re-issues the ingress certificate within
30 days of expiry (`early_renewal_hours`), which changes `build_hash` and
rebuilds the image. The CA and the NeuVector backend certificate are not
renewed; replace the cluster or rotate them (taint `tls_*` resources) before
they expire. The keys live in state and in the image, like `rke2_token`
([ADR 005](005-state-secrets.md)).

### Independence from register
Cross-cluster values are variables, not something `register` hands over.
Shared tokens (`security_join_token`, `observability_bootstrap_token` when
sharing a server) go in `common-all.tfvars`. Endpoints and the CA come from the
outputs of the server or primary cluster (`security.federation_endpoint`,
`observability.url`, `observability.ca_pem`). With sslip.io hostnames the
address is part of the name, so the server or primary cluster is deployed
first; with own DNS names the order is free.

### Federation over 443
NeuVector federation (primary and managed endpoints) goes through a Traefik
`IngressRouteTCP` with TLS passthrough on `websecure`, matching
`HostSNI(fed-<manager host>)`. No NodePort, firewall or load balancer port is
added; the federation services stay ClusterIP. Reachability is `ingress_cidrs`
in both directions: the management cluster admits the downstream egress
addresses and the downstream cluster admits the management ones.

### In-cluster race handling
NeuVector applies `fedinitcfg.yaml` only when its controllers start as a new
cluster (all at once), and keeps the fixed join token in each controller's
memory. A rolling restart therefore neither re-sends a join nor keeps the
token on the primary: every later join fails with "failed to decrypt data".
Nothing restarts the primary for that reason.

- `fedAdmin`: the primary's `userinitcfg` sets `Role: fedAdmin`. It is
  re-applied after the promotion (the reset race in
  [workarounds](../workarounds.md)), so `admin` stays `fedAdmin` without the
  controller restart that would drop the join token.
- `security-fed-init` CronJob (primary, every 5 minutes): applies the
  federation route and reports; it fails visibly when the cluster is not
  `master` or `admin` is not `fedAdmin` 10 minutes after the controllers
  started. It never restarts controllers.
- `security-fed-join` CronJob (downstream): when the controller is not `joint`,
  or reports itself `kicked` (the primary forgot it, e.g. after a full restart
  without persistence), and its oldest pod is older than 10 minutes, it deletes
  all controller pods at once so they start as a new cluster and send the join
  again. This covers a downstream deployed before the primary. Restarts are
  capped at 6 (counter in annotations on the `security-fed-route` ConfigMap),
  then it fails visibly.
- Both log out of the NeuVector REST API after each pass.
- The chart puts checksums of the init ConfigMap and Secret on the controller
  Deployment: editing the primary's NeuVector values by hand (e.g. a new admin
  password) rolls the controllers and drops the join token. Existing members
  keep working; new joins need all controllers restarted at once
  (`kubectl -n cattle-neuvector-system delete pods -l app=neuvector-controller-pod`).

### Observability wiring
- Agent-side self-registration: the downstream token Job also installs the
  `kubernetes-v2` StackPack instance for its own cluster (idempotent check).
  The server needs no list of clusters. On the observability server cluster the
  agent does not self-register `kubernetes-v2`: the SUSE AI extension does it
  for its own cluster, and remote agents register themselves. The extension
  fails on an empty list, so on the server it gets its own `cluster_name` only.
- Hostnames: `obs-<ip>.sslip.io`, `otlp-<obs host>`, `otlp-http-<obs host>`,
  `neuvector-<ip>.sslip.io`, `fed-<neuvector host>`, unless a hostname variable
  is set. With a custom `security_hostname` or `observability_hostname`, DNS
  also needs records for `fed-<neuvector host>`, `otlp-<observability host>` and
  `otlp-http-<observability host>`, all pointing at the ingress address. On aws the address is the public IPv4 of the public NLB network
  interface in the first public subnet (cross-zone is on, so one address reaches
  every target); Rancher keeps the NLB DNS name.
- Precedence: explicit hostname variable, then `ingress_domain`
  (`rancher.<domain>`, `obs.<domain>`, `neuvector.<domain>`), then the provider
  or sslip.io default. Production uses `ingress_domain` with one wildcard record
  (the derived `otlp-`, `otlp-http-` and `fed-` names are one label under the
  domain); the zero-setup default stays sslip.io. With a domain, `ingress_address`
  is not needed and aws skips the NLB interface lookup. A CNAME to the NLB DNS
  name keeps multi-zone failover. `api_host` is unchanged.
- Versions are pinned in one locals table in `elemental-config`. The NeuVector
  chart major follows the Rancher minor from the release manifest (2.13: 108,
  2.14: 109, 2.15: 110); an unknown minor fails at plan. SUSE Observability is
  pinned to 2.10.3 with agent 1.5.40 because 2.11.x has a regression in the SUSE
  AI integration ([workarounds](../workarounds.md)).
- The setup Jobs use `registry.opensuse.org/home/eminguez/containers/leap16/sts-tools`
  (`sts`, `kubectl`, `curl`, `jq`). Its source is a personal OBS project, not a
  SUSE-supported image.
- NeuVector persistence is off and has no variable.

## Consequences
- With a local server the collector sends OTLP over HTTP to the in-cluster
  collector service (4318): gRPC refuses bearer-token credentials on a
  connection without TLS. Remote agents keep OTLP gRPC through the ingress.
- `observability-agent` enables systemd's `sys-kernel-debug.mount` (debugfs) on
  every node: the node agent's eBPF network tracer needs it and the distribution
  preset leaves it disabled.
- The federation `IngressRouteTCP` carries `kubernetes.io/ingress.class: traefik`:
  RKE2's Traefik only reads CRD objects of that class.
- NeuVector gets `global.cattle.clusterName` (`local` with Rancher on the cluster,
  else `cluster_name`): the controller otherwise detects Rancher only if
  `cattle-system` exists when it starts, and NeuVector, installed from a
  `-priority` manifest, usually starts first. Without the Rancher flavor it
  ignores the Rancher session and the extension shows "Authentication failed!".
- State and image carry the CA and TLS keys, the NeuVector admin password and
  join token, the Observability admin password, bootstrap token and license key
  ([security](../security.md#suse-security-and-suse-observability)). Treat state
  as secret.
- The ingress certificate is valid 820 days and is re-issued by an apply
  within 30 days of expiry (an image rebuild); the NeuVector backend certificate
  lasts 5 years and the CA 10, with no renewal. Browsers do not trust the
  per-cluster CA until it is imported (`observability.ca_pem`).
- Adding or changing a component rebuilds the image and replaces the nodes
  (`build_hash`).
- The aws jumphost `user_data` (16 KiB) is now gzipped as a whole
  (`user_data_base64`) instead of per file, which compresses across files, and PEMs are
  embedded as plain text. A management cluster with every component,
  cert-manager, suse-storage and two SSH keys measures 16147 bytes
  (`modules/aws/tests/user-data-size.tftest.hcl`); the precondition fails at
  plan when the limit is exceeded. The changed `user_data` replaces the jumphost of
  existing aws clusters on the first apply after upgrade and the new instance
  re-runs the factory script. With an unchanged `build_hash` the script's
  `is_already_built` hook finds the raw image in S3 and skips the build; when
  the raw has expired (one day, unless `keep_build_artifacts = true`) the image
  is built and uploaded again, and the AMI is not replaced.
- No NeuVector controller PodDisruptionBudget: deriving it from the node count
  would make scaling change `build_hash`. Drain one node at a time.
- Federation trust comes from the join token: the endpoints use the
  controller's self-signed certificate and NeuVector offers no verification.

### Unverified assumptions (confirm in [e2e](../e2e-checklist.md))
- The NeuVector controller sends SNI when it joins, so the Traefik passthrough
  route matches.
- Elemental applies the `HelmChart` objects from `-priority` manifests without
  waiting for them. The federation `IngressRouteTCP` is not an image object:
  the security-fed-* jobs apply it from a ConfigMap once the Traefik CRDs
  exist, because Elemental applies image manifests once.
- The aws jumphost `user_data` fits with every component enabled.
