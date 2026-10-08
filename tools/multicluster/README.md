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
