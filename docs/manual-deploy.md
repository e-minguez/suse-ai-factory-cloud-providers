# Running the deployment with plain Terraform

`examples/<provider>/deploy.sh` is a thin wrapper: it only defines the passes,
and `scripts/lib/{deploy-common,tf}.sh` add the var files, the rebuild counter,
the plan/confirm/apply cycle and the logs. This page lists the equivalent
`terraform` commands, for debugging or for running a single step by hand.

Run everything from `examples/<provider>` or a cluster directory that links to
it.

## Common setup

### Var files

`deploy.sh` passes these files in order (later wins), skipping any that do not
exist. It prints the resolved list on its `var-files` line.

```bash
VF=()
for f in ../../common-all.tfvars ../common-all.tfvars ../common-<provider>.tfvars terraform.tfvars; do
  [ -f "$f" ] && VF+=("-var-file=$f")
done
```

Terraform also loads every `*.auto.tfvars.json` in the directory on its own.
`deploy.sh` uses two of them:

| File | Written by | Content |
|---|---|---|
| `rebuild.auto.tfvars.json` | every run | `{"image_rebuild": N}`, the image rebuild counter |
| `pass2.auto.tfvars.json` | vultr, evroc, exoscale | the values later passes pin (see each provider) |

Both are state, not configuration: keep them next to the state and do not
edit them unless a step below says so. Never set `image_rebuild` in a
`-var-file`; it overrides the auto file and `deploy.sh` refuses to run.

### Init, plan, apply

```bash
[ -d .terraform ] || terraform init -input=false
terraform plan -input=false "${VF[@]}" -out=tfplan   # add the pass's -var flags here
terraform show tfplan                                # review replacements and destroys
terraform apply tfplan
```

Each pass below is one plan/apply cycle with the listed `-var` flags. A plain
`terraform apply "${VF[@]}" <flags>` works too, at the cost of the separate
review step.

### Rebuilding the image

`deploy.sh --rebuild` sets the counter to one more than the larger of the
state's `image.rebuild` output and the file, which changes `build_hash`
([ADR 003](decisions/003-rebuild-counter.md)):

```bash
state=$(terraform output -json image 2>/dev/null | jq -r '.rebuild // 0')
file=$(jq -r '.image_rebuild // 0' rebuild.auto.tfvars.json 2>/dev/null || echo 0)
n=$(( (state > file ? state : file) + 1 ))
printf '{\n  "image_rebuild": %s\n}\n' "$n" > rebuild.auto.tfvars.json
```

Then run every pass of the provider from the first one. A run without
`--rebuild` only writes the file when the state is ahead of it (a lost or
older file), so the image is not rebuilt by accident.

### Destroying

One apply for every provider; the auto files are loaded as usual:

```bash
terraform destroy "${VF[@]}"
```

`deploy.sh --destroy` runs the same with a reviewed plan, then prints the read-only
`tools/leftovers/<provider>.sh` command to run; a bare `terraform destroy` does not.

## aws: 1 pass

The API address (NLB DNS name) is known at plan time and target group
attachments are separate resources, so nothing waits on a created instance.

```bash
terraform plan -input=false "${VF[@]}" -out=tfplan && terraform apply tfplan
```

When the AWS CLI is on `PATH`, `deploy.sh` first runs `aws sts get-caller-identity`
to fail early on invalid credentials, and probes `iam:CreateRole` unless
`--destroy` is used or `vmimport_role_name` and `jumphost_instance_profile_name`
are set. The CLI is
required anyway: `modules/aws/scripts/wait-for-raw.sh` uses it during apply.

## vultr: 2 passes

**Why:** `vultr_load_balancer` carries its backends (`attached_instances`) and
forwarding rules inline. The load balancer address is baked into the image,
the nodes boot from that image, so a backend list that references the nodes
closes a dependency cycle. The module takes the backends as variables instead,
filled from the pass 1 outputs. The jumphost tcp/80 rule the snapshot import
needs is also a resource, and it cannot be created and removed in one apply.
Details: [providers/vultr.md](providers/vultr.md#passes-2-and-why).

**Pass 1, create infrastructure.** On a first deploy, or when this pass replaces
a node, the NAT gateway or the snapshot, reset the backend lists, so a replaced
node is not attached by its stale ID, and leave `image_import_port_open` at its
default (`true`) so a rebuild can be imported. Otherwise keep the file: a reset
detaches the load balancer backends until pass 2.

```bash
printf '%s\n' '{"lb_backend_instance_ids":[],"lb_supervisor_extra_cidrs":[],"agent_cloud_extra_cidrs":[]}' > pass2.auto.tfvars.json
terraform plan -input=false "${VF[@]}" -out=tfplan && terraform apply tfplan
```

This creates the load balancers without backends, the NAT gateway, the
jumphost, the image build, the snapshot import and the nodes.

**Pass 2, attach load balancer backends.** Pin the backend lists from pass 1
and close tcp/80:

```bash
terraform output -json provider_details | jq '{
  lb_backend_instance_ids: .control_plane_ids,
  lb_supervisor_extra_cidrs: .agent_node_cidrs,
  agent_cloud_extra_cidrs: .nat_gateway_public_cidrs,
  image_import_port_open: false
}' > pass2.auto.tfvars.json
terraform plan -input=false "${VF[@]}" -out=tfplan && terraform apply tfplan
```

Later plain applies keep these values. Run both passes again after anything
that replaces a node (a count change, a rebuild), otherwise the load balancers
point at instances that no longer exist.

Vultr credentials come from `vultr_api_key` in the var files; the provider and
the wait scripts read nothing from the environment.

## evroc: 2 passes plus an optional third

**Why:** `evroc_snapshot` only takes a disk, so each zone's build host writes
the image to an attached disk, and the snapshot is taken from the detached
disk. A disk cannot be attached and detached in one apply (passes 1 and 2).
Creating a snapshot and deleting its source disk in one apply depends on an
ordering Terraform does not pin down, so reclaiming the disks is a third
apply. Snapshots are zonal, so every pass covers every zone. Details:
[providers/evroc.md](providers/evroc.md#passes).

`image_ready` sequences the passes; `pass2.auto.tfvars.json` pins it to `true`
once the snapshots exist.

### New image (first deploy or rebuild)

```bash
rm -f pass2.auto.tfvars.json

# Pass 1, build image: network, API VIP, load balancer, build hosts, image disks.
terraform plan -input=false "${VF[@]}" -var=image_ready=false -out=tfplan && terraform apply tfplan

# Pass 2, create nodes: detach, snapshot each disk, create the nodes; keep the disks.
terraform plan -input=false "${VF[@]}" -var=image_ready=true -var=keep_build_artifacts=true -out=tfplan && terraform apply tfplan

printf '{\n  "image_ready": true\n}\n' > pass2.auto.tfvars.json

# Pass 3, reclaim build disks. No changes when keep_build_artifacts = true is in terraform.tfvars.
terraform plan -input=false "${VF[@]}" -var=image_ready=true -out=tfplan && terraform apply tfplan
```

On a rebuild with snapshots already in state, pass 1 destroys them and every
node is replaced.

### Snapshots already in state

`deploy.sh` checks for existing snapshots and, without `--rebuild`, applies
once:

```bash
terraform output -json image | jq -e '[(.ids // {}) | to_entries[] | select(.value != null)] | length > 0'
terraform plan -input=false "${VF[@]}" -var=image_ready=true -out=tfplan && terraform apply tfplan
printf '{\n  "image_ready": true\n}\n' > pass2.auto.tfvars.json
```

Never apply with `image_ready=false` here unless a new image is intended: it
destroys the snapshots.

### Retries and crash recovery

- `deploy.sh` tries a pass up to 3 times when the apply fails with
  `API error (409)` (concurrent load balancer writes). By hand: run the same
  plan/apply again.
- On a Terraform 1.16.4 crash
  ([hashicorp/terraform#39283](https://github.com/hashicorp/terraform/issues/39283))
  resources created during the crashed apply are missing from state.
  `deploy.sh` prints the `tools/orphans/evroc -- -var=image_ready=<pass value>`
  command (it adds the var files itself), which writes
  `orphan-imports.tf.proposed` with import blocks for them; review it, rename
  it to `imports.tf`, retry the pass and delete `imports.tf` afterwards. With
  `EVROC_ADOPT_ON_CRASH=1`, `deploy.sh` runs it with `--adopt` (writes
  `imports.tf` directly) and retries the pass once.

`deploy.sh` also requires `~/.evroc/config.yaml` (`evroc login`).

## exoscale: 2 passes

**Why:** the load balancer targets one instance pool, and every member of a
pool gets the same `user_data`, so the control plane pool starts with one
member that initializes the cluster and then switches to the join
configuration. Details:
[providers/exoscale.md](providers/exoscale.md#passes-2-and-why).

`pass2.auto.tfvars.json` pins `cp_initialized` and `image_import_port_open`.

### New cluster

```bash
# Pass 1, bootstrap control plane: pool of size 1 with the init configuration,
# workers, jumphost, image build and template. Ends when the API answers.
printf '%s\n' '{"cp_initialized":false,"image_import_port_open":true}' > pass2.auto.tfvars.json
terraform plan -input=false "${VF[@]}" -out=tfplan && terraform apply tfplan

# Pass 2, scale control plane: join configuration, pool scaled to
# control_plane_count, jumphost tcp/80 closed.
printf '%s\n' '{"cp_initialized":true,"image_import_port_open":false}' > pass2.auto.tfvars.json
terraform plan -input=false "${VF[@]}" -out=tfplan && terraform apply tfplan
```

Rerun pass 1 as it is when it fails: the pin stays `false` until it finishes.

### Pool already in state

`deploy.sh` treats the cluster as bootstrapped when
`module.ai_factory.exoscale_instance_pool.control_plane[0]` is in
`terraform state list` and the pin is not `false`, and applies once with
`cp_initialized = true`. Before applying, check the plan:

- it must not create or replace `exoscale_instance_pool.control_plane`
  without a new image (see below): the new members would have no cluster to
  join;
- it must not change the pool `size` from more than 1 to 1: that removes
  members and brings back the init configuration (`cp_initialized` is wrong);
- when it replaces the pool together with `random_id.serve_path` (a new image,
  for example a rebuild), every node is replaced: run the two passes of
  [New cluster](#new-cluster) instead (pins `false`/`true`, then
  `true`/`false`);
- when it creates an `exoscale_template` without replacing the pool, set
  `image_import_port_open` to `true`, plan and apply, then set it back to
  `false` and apply again to close tcp/80.

```bash
printf '%s\n' '{"cp_initialized":true,"image_import_port_open":false}' > pass2.auto.tfvars.json
terraform plan -input=false "${VF[@]}" -out=tfplan
terraform show -json tfplan | jq '[.resource_changes[] | select(.type == "exoscale_template" and (.change.actions | index("create")))] | length'
terraform apply tfplan
```

Never set `cp_initialized = false` on a running cluster.

The API key and secret come from `exoscale_api_key` and `exoscale_api_secret`
(var files or `TF_VAR_*`). `deploy.sh --destroy` deletes
`pass2.auto.tfvars.json` after the destroy.
