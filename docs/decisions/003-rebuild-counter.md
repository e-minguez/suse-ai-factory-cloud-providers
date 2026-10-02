# 003 - Rebuild counter

## Status
Accepted.

## Context
`build_hash` is the only image rebuild trigger. `deploy.sh --rebuild` used to
force a build by replacing one resource per provider. On aws the replaced
resource did not change the build identity, so the raw image, snapshot and AMI
were reused. On evroc the primary-zone build host was not covered by the
replacement.

## Decision
- Common variable `image_rebuild` (whole number, default 0) feeds `build_hash`
  when greater than 0, so the default leaves existing hashes unchanged.
- `deploy.sh --rebuild` reads the current value (the larger of the state's
  `image.rebuild` and `rebuild.auto.tfvars.json`), adds 1 and writes the file.
  Later runs keep the value because Terraform loads `*.auto.tfvars.json`.
- No `-replace` of individual resources. A new hash changes the build id, and
  with it the aws raw key, AMI name and jumphost user data, the evroc
  snapshot names and build hosts, and the vultr serve path and snapshot.
- evroc builders are replaced by `terraform_data.build_identity`, so every new
  build id starts a fresh factory run on them. The jumphost (primary zone) is
  the bastion and is not in that trigger; a new build id changes its user data.
- `--rebuild` on evroc always runs pass 1, also with snapshots in state.

## Consequences
- Do not set `image_rebuild` in any var file: an explicit var file wins over
  the auto file, and `deploy.sh` refuses to run `--rebuild` with it set.
- A plain `deploy.sh` run rewrites the file from state when state is ahead
  (fresh checkout, deleted file), so the image is not rebuilt by accident.
- Bumping the counter replaces every node, like any other image change.
