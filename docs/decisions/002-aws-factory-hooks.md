# 002 - aws: image-factory hooks

## Status
Accepted.

## Context
The aws jumphost runs the shared `modules/image-factory` script. Its S3
existence check and its delivery are aws-specific hooks.

## Decision
- The existence check uses `list-objects-v2 --prefix <raw_key>`, not
  `head-object`. For a caller whose `s3:ListBucket` is prefix-conditioned, a
  HEAD on a missing key returns 403, which cannot be told apart from a real
  AccessDenied. A LIST under `images/` is what the jumphost role permits.
- The check looks at the raw in S3, not the AMI: Terraform registers the AMI
  and the jumphost role holds no EC2 permissions.
- The raw expires one day after upload unless `keep_build_artifacts` is set. A
  jumphost replaced after that rebuilds and re-uploads the raw; the import has
  already happened, so nothing waits on it.
- `pre_build` runs before the check because the check needs the AWS CLI,
  which has no zypper package and is installed from the AWS bundle.
- The raw key appears only after the multipart upload completes;
  `modules/aws/scripts/wait-for-raw.sh` relies on that.
- The stripped script and the Elemental config ship inline in the gzipped
  cloud-init, so the jumphost reads nothing from S3 except this existence
  check, and the 16 KiB EC2 `user_data` limit applies to them (plan
  preconditions check it).

## Consequences
Rebuilds are triggered only by `build_hash`. The bucket, raw key and build id
are placeholders in the shared script, so its `script_hash`, which feeds
`build_hash`, covers the script template and the hooks but not values derived
from the hash. The real values are substituted afterwards.
