# multicluster

Runs several clusters from one checkout and imports them into the Rancher of a
management cluster. Any provider can be the management cluster or a downstream
cluster, because every provider exposes the same outputs.

```
cluster.sh new [--empty] <provider> <name>
cluster.sh deploy <name> [deploy.sh args]
cluster.sh destroy <name> [deploy.sh args]
cluster.sh register [--bootstrap] [--skip-cidr-check] [--yes] <mgmt> <downstream...>
cluster.sh list
cluster.sh cost <name> [cost args]
```

## Working area

`clusters/` at the repo root is gitignored.

```
clusters/
  common-all.tfvars          values every provider declares (see common-all.tfvars.example)
  common-<provider>.tfvars   provider credentials, region, sizes
  common-register.tfvars     optional: rancher_token, rancher_insecure
  <name>/                    main.tf, variables.tf, outputs.tf, versions.tf, deploy.sh:
                               symlinks to examples/<provider>/
                             kubeconfig.sh, ssh.sh, build-logs.sh: symlinks to scripts/
    .provider                provider name
    terraform.tfvars         per-cluster values (mode 600)
  .register/<mgmt>/          state of the register root for that management cluster
```

`new` refuses to overwrite an existing cluster and copies the example's
`terraform.tfvars.example` to the cluster's `terraform.tfvars`; with `--empty` the
file is created empty (mode 600) instead. The linked helper
scripts default `-C` to the cluster directory, so `clusters/<name>/ssh.sh <host>`
works from anywhere. The cluster directory sits at the same depth as
`examples/<provider>`, so the relative module sources resolve. `deploy` and
`destroy` run the cluster's `deploy.sh` (`destroy` is `deploy.sh --destroy`) and
pass extra arguments through. `deploy.sh`
layers the var files itself (later wins): the repo root `common-all.tfvars`,
`clusters/common-all.tfvars`, `clusters/common-<provider>.tfvars`,
`terraform.tfvars`. `list` prints each cluster with its provider and whether its
state holds resources.
`cost` runs the [cost estimator](../cost/README.md) (needs Go) for the cluster's
provider with the same var files, in the same order; extra arguments such as
`--json` or `--region` pass through. It is an estimate only.
Plain `terraform` commands in a cluster directory need the same var files;
see [Running with plain Terraform](../../docs/manual-deploy.md#var-files).

Worked examples with diagrams and per-cluster variable files: [catalog/](../../catalog/README.md).

## Management and downstream clusters

`components` is a per-cluster variable, so each cluster sets its own list in
`clusters/<name>/terraform.tfvars`, which wins over `common-all.tfvars`. A
management cluster runs Rancher and the AI Factory operator; downstream
clusters run the GPU stack. A downstream cluster needs a storage component
(`local-path-provisioner` or `suse-storage`, both from Application Collection,
so `appco_username` and `appco_password` must be set). For `suse-storage`,
`suse_storage_nodes` sets where its disks live (default the control-plane
nodes; see [Storage](../../README.md#storage)).

```
tools/multicluster/cluster.sh new vultr mgmt
tools/multicluster/cluster.sh new aws gpu-a
```

```hcl
# clusters/mgmt/terraform.tfvars
components = ["rancher", "aif-operator"]  # cert-manager comes with rancher
# gpu_pools defaults to {}: no GPU nodes

# clusters/gpu-a/terraform.tfvars
components = ["cert-manager", "gpu-operator", "local-path-provisioner"]
gpu_pools  = { gpu = { instance_type = "...", count = 2 } }
```

```
tools/multicluster/cluster.sh deploy mgmt
tools/multicluster/cluster.sh deploy gpu-a
tools/multicluster/cluster.sh register --bootstrap mgmt gpu-a
```

- `aif-operator` requires `rancher` in the same list (validated at plan).
  cert-manager is not listed with rancher: elemental installs chart
  dependencies from the release manifest.
- Without `rancher`, the `rancher_*` outputs are null; `register` only needs
  them from the management cluster.
- Either role can be a [single-node cluster](../../README.md#single-node-clusters)
  (`control_plane_count = 1`) and grow later.
- `components` is an image input: changing it rebuilds the image and replaces
  every node of that cluster.

## SUSE Security and SUSE Observability across clusters

[ADR 010](../../docs/decisions/010-security-observability.md). `register` is
**not** required: the components take every cross-cluster value from variables,
so they work with clusters that are not imported into Rancher.

Components: the management cluster runs `security-management` and
`observability-server` (plus `observability-plugin` with Rancher); each
downstream cluster runs `security-downstream` and `observability-agent`. Both
need Traefik; the server needs a storage component, `observability_license_key`
and the Application Collection credentials.

```hcl
# clusters/common-all.tfvars: shared tokens, identical on every cluster
security_join_token           = "<uuid, lowercase>"
observability_bootstrap_token = "<random>"

# clusters/mgmt/terraform.tfvars
components = ["rancher", "aif-operator", "local-path-provisioner",
              "security-management", "observability-server", "observability-plugin"]
observability_license_key = "..."

# clusters/gpu-a/terraform.tfvars: a cluster_name different from mgmt's
cluster_name = "gpu-a"
components = ["cert-manager", "gpu-operator", "local-path-provisioner",
              "security-downstream", "observability-agent"]
# the mgmt-derived values come from addons.auto.tfvars.json, below
```

### Downstream values from the management outputs

Generate the downstream cluster's cross-cluster values from the management
cluster's outputs instead of copying them by hand. Terraform loads every
`*.auto.tfvars.json` in the cluster directory on its own, so `deploy.sh` picks
the file up without a `-var-file` (it is not listed in its `var-files` line):

```bash
terraform -chdir=clusters/mgmt output -json | jq '{
  security_primary_endpoint: .security.value.federation_endpoint,
  observability_server_url:  .observability.value.url,
  observability_ca_pem:      .observability.value.ca_pem,
  security_rancher_url:      .rancher_url.value
}' > clusters/gpu-a/addons.auto.tfvars.json
chmod 600 clusters/gpu-a/addons.auto.tfvars.json
tools/multicluster/cluster.sh deploy gpu-a

# optional: import gpu-a into the management Rancher (NeuVector SSO, extension views)
tools/multicluster/cluster.sh register --bootstrap mgmt gpu-a
```

- `register` needs a Rancher API token. A freshly deployed management Rancher
  has none, so the first `register` against it uses `--bootstrap`: it logs in
  with the `rancher_bootstrap_password` output, creates an admin token, keeps it
  in `clusters/.register/mgmt/` and replaces the admin password (see
  [Register](#register) for reading the new one). Later runs against the same
  management cluster remember the choice; without a token and without
  `--bootstrap`, `register` stops and says so. A rebuilt management cluster is a
  fresh Rancher: delete `clusters/.register/mgmt/` and use `--bootstrap` again.
- Browsers must trust the cluster CA for the NeuVector and Observability UIs
  and the Rancher Observability extension: see
  [Trusting the cluster CA](../../docs/security.md#trusting-the-cluster-ca-in-the-browser).

- Run it after the management cluster is deployed, and again whenever it is
  rebuilt: the endpoint and the CA change with every new management cluster.
- Values in `terraform.tfvars` (and the common files) win over the auto file;
  leave these four variables out of them.
- The plan fails at a precondition when `security-downstream` lacks
  `security_primary_endpoint`, so a plan that passes it has read the file.
- Without Rancher on the management cluster `rancher_url` is null, which leaves
  NeuVector Rancher SSO off. With it, import the downstream cluster under its
  `cluster_name` (`cluster.sh register` does) so Rancher SSO matches it.

- Read the values with `terraform -chdir=clusters/mgmt output -json security`
  and `... output -json observability`. `observability.ca_pem` is a certificate,
  not a secret. `security_join_token` and `observability_bootstrap_token` in
  `common-all.tfvars` give both sides the same value; if you leave them null the
  management cluster generates them, and the downstream cluster cannot learn
  them without you copying `security_credentials` and `observability_credentials`.
- The server or primary cluster comes first when the hostnames are sslip.io
  ones (they contain the ingress address). With own DNS names
  (`security_hostname`, `observability_hostname`) the order is free: the
  `security-fed-join` CronJob joins a downstream cluster deployed earlier.
  `ingress_domain` (`obs.<domain>`, `neuvector.<domain>`) counts as own DNS
  names and needs only the wildcard record `*.<domain>`.
  Custom hostnames need DNS records, all pointing at the ingress address, for
  `fed-<security_hostname>`, `otlp-<observability_hostname>` and
  `otlp-http-<observability_hostname>` too.
- A plugin (`observability-plugin`) on a remote Rancher needs that Rancher URL,
  with the trailing slash (`https://rancher.example.com/`), in the server's
  `observability_allowed_origins`.
- Federation uses port 443 (Traefik SNI passthrough). Each side needs the
  other in `ingress_cidrs`: the management cluster admits the downstream
  `egress_ips`, and the downstream cluster admits the management ones. The
  downstream agent and collector also reach the Observability ingresses
  (UI/API, OTLP gRPC and HTTP) on the management cluster over 443.
- A downstream cluster registers itself in SUSE Observability from its own
  setup Job; the server needs no cluster list.
- `components` and the TLS inputs are image inputs: changing them rebuilds the
  image and replaces the nodes of that cluster.

## Register

`register` runs `register/`, a small Terraform root with the `rancher2`
provider. It creates one imported cluster (`rancher2_cluster`) per downstream
cluster in the management Rancher, then applies each registration manifest on the
downstream init node over SSH with the node's own `kubectl`. No admin kubeconfig
is written locally.

- Inputs come from `terraform output` of the cluster directories and reach
  Terraform through environment variables (`TF_VAR_*`). Only names, provider and
  egress IPs are passed, and no secret is written to a file by `cluster.sh`. The
  register state holds the registration tokens (the manifest URLs), so
  `clusters/.register/<mgmt>/` is created mode 700; treat it as a secret.
- Clusters accumulate: `register mgmt a` then `register mgmt b` keeps both. To
  remove one, delete the cluster in Rancher and edit
  `clusters/.register/<mgmt>/downstream.list`.
- `--yes` passes `-auto-approve` to the register apply.
- Re-running is safe: a downstream that already has `cattle-cluster-agent` is skipped.

### Rancher API token

Provide one of these, never in the repo:

- `export RANCHER_TOKEN_KEY=<access:secret>` (an API key created in the Rancher UI).
- `rancher_token = "<access:secret>"` in `clusters/common-register.tfvars`.
- `--bootstrap`: first login only. Uses the management cluster's
  `rancher_bootstrap_password` output to create an admin token, which is stored in
  the register state (`clusters/.register/<mgmt>/`). The choice is remembered for
  later runs of that management cluster. Treat that state as a secret.
  `rancher2_bootstrap` also replaces the admin password with a random one, so
  the `rancher_bootstrap_password` output no longer logs in afterwards. Read the
  new one with
  `TF_DATA_DIR="$PWD/clusters/.register/<mgmt>/.terraform" terraform -chdir=tools/multicluster/register output -raw admin_password`
  from the repo root.

Rancher's default certificate comes from a private CA, so `rancher_insecure`
defaults to `true` (Terraform and the manifest download skip verification). Set
`rancher_insecure = false` in `clusters/common-register.tfvars` when Rancher has
a trusted certificate.

### Network

The downstream agent connects to the management `rancher_hostname`, so the
management `ingress_cidrs` must include the downstream `egress_ips`. `register`
prints the egress IPs, reads the management `ingress_cidrs` with `terraform
console`, and stops when an IP is not covered. `--skip-cidr-check` continues
anyway. When a provider reports no egress IPs, or the CIDRs cannot be read, it
only warns.

## Tests

`scripts/tests/multicluster_test.sh` (fake terraform, ssh, curl) and
`terraform test` in `register/` (mock `rancher2` provider). Both run in `make test`.
