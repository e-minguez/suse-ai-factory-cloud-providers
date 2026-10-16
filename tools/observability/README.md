# observability

Optional manifests for clusters that run `observability-agent` (alone or with
`observability-server`). They are not part of the image: apply them after the
cluster is up. The agent, the OpenTelemetry Collector and the server come from
the `observability-*` components
([ADR 010](../../docs/decisions/010-security-observability.md)).

| File | Purpose |
|---|---|
| `otel-operator.yaml` | OpenTelemetry Operator (Application Collection chart) for [auto-instrumentation](https://documentation.suse.com/cloudnative/suse-observability/latest/en/setup/otel/getting-started/getting-started-k8s-operator.html). It deploys no collector: instrumented pods send to the collector installed by `observability-agent`. |
| `instrumentation.yaml` | `Instrumentation` CR for the operator. Apply it in each namespace to instrument, once the operator CRDs exist, then annotate the pods (`instrumentation.opentelemetry.io/inject-<java\|nodejs\|python\|dotnet\|go>: "true"`). Go also needs `instrumentation.opentelemetry.io/otel-go-auto-target-exe`. |
| `demo-app.yaml` | Example GenAI application (Python, OpenLIT SDK) that asks the vLLM API a question every 30 s, with traces, token metrics and cost in the SUSE AI views. The init container installs `openlit` and `openai` from PyPI, so the cluster needs internet access. |

## Prerequisites

- The cluster has `observability-agent` or `observability-server` in
  `components` (the collector is `opentelemetry-collector.open-telemetry`).
- `otel-operator.yaml`: Application Collection credentials
  (`appco_username`, `appco_password`).
- `demo-app.yaml`: a vLLM endpoint in `<SUSE_AI_NAMESPACE>` (default
  `suse-private-ai`, the `observability_suse_ai_namespace` default).
- `terraform`, `jq`, `base64`, `sed` on the workstation, and a kubeconfig for
  the cluster ([`scripts/kubeconfig.sh`](../../scripts/kubeconfig.sh)).

## Usage

`render.sh <cluster-dir> <manifest> [KEY=VALUE...]` reads
`terraform -chdir=<cluster-dir> output -json`, replaces the `<PLACEHOLDER>`
values, fails when one is left and prints the result to stdout. Nothing is
written to disk: pipe it to `kubectl`.

| Placeholder | Source |
|---|---|
| `<SUSE_AI_NAMESPACE>` | `SUSE_AI_NAMESPACE` (argument or environment), default `suse-private-ai` |
| `<APPCO_DOCKERCONFIGJSON_BASE64>` | `APPCO_DOCKERCONFIGJSON_BASE64`, or built from `APPCO_USERNAME` and `APPCO_PASSWORD` (`APPCO_REGISTRY`, default `dp.apps.rancher.io`) |

The Application Collection credentials are not Terraform outputs: pass them as
environment variables (preferred, they stay out of the process list) or as
`KEY=VALUE` arguments. `<CLUSTER_NAME>` (output `cluster_name`) is also replaced when a
manifest uses it; none of the shipped ones does. Any other `<PLACEHOLDER>` you
add to a copy of a manifest can be given as `KEY=VALUE`.

```bash
CL=clusters/gpu-a   # or examples/<provider>
export APPCO_USERNAME=... APPCO_PASSWORD=...

tools/observability/render.sh "$CL" tools/observability/otel-operator.yaml | kubectl apply -f -
# once the operator CRDs exist (the first apply fails with no matches for kind "Instrumentation")
tools/observability/render.sh "$CL" tools/observability/instrumentation.yaml | kubectl apply -n <app-namespace> -f -
tools/observability/render.sh "$CL" tools/observability/demo-app.yaml | kubectl apply -f -
```

Use the kubeconfig of the target cluster for `kubectl`, for example
`scripts/kubeconfig.sh -C "$CL" -o /tmp/gpu-a.kubeconfig` and
`KUBECONFIG=/tmp/gpu-a.kubeconfig`. The kubeconfig is an admin credential: see
[docs/security.md](../../docs/security.md#kubeconfig-and-ssh).
