# CLAUDE.md

Deploys SUSE AI Factory (RKE2 + Rancher + AI Factory operator + NVIDIA GPU
operator on a SUSE Elemental image) on multiple cloud providers from one repo:
`github.com/e-minguez/suse-ai-factory-cloud-providers`. Public, community project, not an official SUSE product.

## Status
- `v0.1.0` is the first release. End-to-end checks not yet run: `docs/e2e-checklist.md`; everything else passed on all three providers.
- Releases: release-please (`release-please-config.json`, `.release-please-manifest.json`, `version.txt`) opens a release PR from Conventional Commits on `main`; merging it tags `vX.Y.Z` and writes `CHANGELOG.md`. Never edit `CHANGELOG.md` or the version by hand. PR titles must be Conventional Commits (`pr-title` workflow, required check); user-facing changes (variables, outputs, `deploy.sh` interface) are `feat`/`fix`, breaking ones `!`. Pre-1.0: `feat` and `!` bump minor, `fix` bumps patch.
- `main` is protected (ruleset `protect-main`): no direct pushes, force pushes or history rewrites. Every change goes through a PR from a branch, squash-merged only (the PR title becomes the commit) once the 15 required checks pass (14 CI checks, including `webui-test` and `image` (hadolint, build, smoke test), + `conventional-title`). Renaming or adding a CI job (a new provider adds `validate (<provider>)`) means updating the ruleset's required checks.
- Actions in `.github/workflows/*.yml` are pinned to commit SHAs (version in a trailing comment); dependabot bumps them and the `tools/cost` Go modules weekly.
- The user runs all end-to-end deploys. Only provide commands and checks.

## Layout
- `modules/elemental-config`, `modules/image-factory`, `modules/rke2-ports`: shared.
- `modules/common/variables-common.tf`: common variable declarations, **symlinked** into each provider module (Terraform cannot import variables). Edit the original, never the link.
- `modules/<provider>`: provider modules. `examples/<provider>`: single-cluster roots with `deploy.sh`.
- `tools/multicluster` (uses the `rancher2` provider), `tools/leftovers/<provider>.sh` (on `scripts/lib/leftovers.sh`, suggested, never run, by `deploy.sh --destroy`), `tools/orphans/evroc`, `tools/vultr/passthrough-stock.sh`; `tools/cost` (Go): pre-deploy cost estimate from tfvars for aws, evroc, exoscale and vultr (`make cost`, `cluster.sh cost`; ADR 007). Estimate only; per-provider defaults are locked to `locals.tf` by `TestDefaultsMatchLocals`.
- `tools/webui` (Go, ADR 009, **alpha**, own version in `tools/webui/VERSION`; image tags `<that version>` + `vX.Y.Z`, no `latest`): localhost runner UI over `cluster.sh`/`deploy.sh`; `ui.yaml` drives basic/advanced forms with `variables.tf`; user guide `docs/webui.md`; image `tools/webui/Dockerfile` (BCI golang → scratch + bci-micro rootfs, pinned Terraform, providers mirrored after `terraform get`, aws CLI (pinned, GPG) + evroc CLI (`latest`, sha256), `.hadolint.yaml`); `HOME=/opt/aif/clusters/.home`; run with `--init --read-only --tmpfs /tmp`.
- `scripts/lib/{tf.sh,poll.sh,deploy-common.sh,ssh.sh,leftovers.sh}`, `scripts/{kubeconfig,ssh,build-logs}.sh`.
- `docs/decisions/NNN-*.md` (ADRs), `docs/workarounds.md`, `docs/providers/<p>.md`, `docs/conventions.md` (naming, labels, outputs), `docs/architecture.md` (Mermaid diagrams: flow, image pipeline, passes, network; update when a pass, role or traffic path changes).

## Conventions
- One naming style for every provider (`docs/conventions.md#naming`). New providers follow it; no provider-specific names for common concepts.
- Every provider exposes the identical output set (`docs/conventions.md#outputs`); provider-only data goes in `provider_details`.
- Every provider ships `examples/<p>/deploy.sh` (aws too, even though it is single pass), same interface: `deploy.sh [--rebuild] [--yes] [-v|-q] [--destroy] [-- <tf args>]`. It only defines passes; everything else is in `scripts/lib/tf.sh`.
- Tfvars layering: `common-all.tfvars` (credentials and values shared by every provider) → `common-<provider>.tfvars` → per-cluster `terraform.tfvars`. Later wins. `common-all.tfvars` may only contain variables every provider declares.
- Every provider labels resources the same way (`docs/conventions.md#labels`): `elemental-{cluster,managed-by,module,created}` everywhere, plus `role` (fixed vocabulary), `pool`, `build`, `listener` where they apply; `created` = UTC `YYYYMMDD-hhmmss` of the first apply. `var.tags` cannot use the prefix. No `/` in keys: evroc rejects it.
- `aif_release`: a value matching `^https?://` is a manifest URL; anything else is a version resolved to tag `aif-operator-<version>`.
- The image is rebuilt only when `build_hash` changes. **Every** build input (config files, manifest, sysexts, overrides such as `core_platform_override`) must feed `build_hash`, or changing it silently keeps the old image.
- `deploy.sh --rebuild` forces a rebuild by bumping a persisted rebuild counter that feeds `build_hash` (no `-replace` of individual resources).
- Availability and quota checks hard-fail at plan in every provider (postconditions/preconditions, not warning `check` blocks).

## Writing style
- Comments: what + non-obvious constraint, ≤ ~3 lines. Rationale and history go to `docs/decisions/`.
- **Neutral tone about cloud providers** in code, docs, ADRs and commits: state platform behaviour as fact and the resulting choice. No blame or judgement. Upstream bugs link to their issue and go in `docs/workarounds.md`.
- No cross-provider comparisons in provider code ("unlike X…").
- No Python embedded in bash. Data transforms happen in Terraform at plan time; scripts use `jq`/`yq` at most.
- Accepted Python on instances (not in bash): vultr and exoscale serve the image with `python3 -m http.server`; evroc runs `status-relay.py` on the jumphost. No other Python.
- Variable descriptions: 1–2 sentences.

## Security rules
- Never print, commit or copy the contents of `terraform.tfvars`, `*.tfstate*`, kubeconfigs or `.deploy/` logs.
- `scripts/kubeconfig.sh` is never run automatically: stdout by default, `-o` creates mode 600 and refuses to overwrite without `--force`. `deploy.sh` only prints how to fetch it.
- SSH uses a throwaway `ssh_config` + `known_hosts` in `mktemp -d` (`StrictHostKeyChecking accept-new`, `ProxyJump` via jumphost). No Terraform-managed SSH host keys.
- `rke2_token` is not an output. It still lives in state via user_data (decided, `docs/decisions/005-state-secrets.md`): treat state as secret and recommend an encrypted remote backend. Don't reintroduce the output or try to move the token out of user_data.
- Instances must not read from S3/object storage. The only exception is the aws jumphost uploading the raw image.

## Image and node facts
- The Elemental image has **no sudo**. Login is `node_username` + `su -`. RKE2 sets `write-kubeconfig-group: <node_username>` and `write-kubeconfig-mode: "0640"` so tooling never needs root. `permit_root_ssh` is a debug toggle, default false.
- Ignition runs with most of the filesystem read-only. Anything depending on runtime state (network, NICs, sysext binaries) is a script written by Ignition plus a systemd oneshot unit or an elemental initrd hook, not a static config file.
- `write-node-ip.sh` is required: bare-metal nodes have two NICs with default gateways and RKE2 would otherwise pick the public one. Single NIC → no-op; else pick the IPv4 inside `vpc_cidr`.
- `configure-network.sh` (initrd hook, evroc and vultr) is required there: MTU and the dual-NIC bare-metal case.
- `ignition.platform.id`: aws → `aws`, vultr → `vultr`, evroc → `proxmoxve`, exoscale → `exoscale` (metadata service only: private instances cannot boot Elemental).
- GA `elemental3ctl` 3.0.x ignores `initrdExtensions`; hence the `core_platform_override` / `sysext_image_overrides` beta workarounds. Remove once a GA image ships elemental3ctl ≥ 3.1.
- GPU operator uses a precompiled SLES 16.1 driver override until the driver packages are published.
- Comments are stripped from rendered configs before hashing and before user_data.

## Provider facts
- user_data limits: EC2 16 KiB (gzip + comment strip + size preconditions), vultr 32 KiB, evroc 768 KiB, exoscale 32768 base64 characters (~24 KiB).
- Passes: aws 1; vultr 2 (LB address in the image ↔ inline LB backends cycle; ADR 006); evroc 2 (a disk cannot be attached and detached in one apply) + optional 3rd to reclaim build disks. exoscale 2 (NLB targets instance pools only and a pool has one user_data: control plane pool bootstraps with one init member, then join config + scale-up; ADR 008).
- Hostnames: sslip.io works for Rancher and the RKE2 API on vultr, evroc and exoscale (confirmed by the user); aws uses NLB DNS names.
- aws: AMI via S3 + `aws_ebs_snapshot_import`; single regional image.
- vultr: snapshot via `vultr_snapshot_from_url` from an HTTP server on the jumphost; account-wide; single location, no zones.
- evroc: image `dd`'d to a disk then `evroc_snapshot`, **one snapshot per zone**; VMs need the `compute-experimental-features-UEFI` label; no serial console, so build progress is relayed over HTTP; the platform sets MTU 8900 via DHCP (pod MTU = vpc_mtu − 50); egress without a public IP.
- exoscale: qcow2 only (raw converted on the jumphost, virtual size grown to ≥ 10 GiB), `exoscale_template` per zone; single zone; every node has a public IPv4 (NLB direct return, metadata), the jumphost is the only SSH entry and agents have no inbound rules; NLB healthchecks come from the managed SG `public-nlb-healthcheck-sources`; pool members get the private NIC hot-plugged and take hostname and RKE2 node-name from metadata; quota and type checks are signed API reads (`scripts/exoscale-api.sh`, `openssl`).

## Tooling
- Terraform 1.16.4 crashes (hashicorp/terraform#39283). 1.16.5 is **not released yet**; keep the crash handling in `scripts/lib/tf.sh` until it is, then set `required_version >= 1.16.5`.
- `deploy.sh` flow: `plan -out` → show replacements/destroys → confirm (unless `--yes`) → `apply -json` of the saved plan rendered by `jq`. Full logs in `.deploy/logs/<ts>/` (gitignored).
- Event protocol (opt-in, CLI unchanged when unset): `DEPLOY_EVENTS_FD=<n>` gets JSON lines from `tf.sh`/`deploy-common.sh`; `DEPLOY_CONFIRM_FD=<n>` supplies the confirm answer without TTY or `--yes`. Keep both in step with the webui parser.
- webui: binds localhost, token → cookie, Host/Origin checks, strict CSP, secrets write-only and redacted; volume `/opt/aif/clusters` is the secret and shares `cluster.sh` layout. SSH keys are resolved once (feed `build_hash`). Stop with `docker stop -t 600`; run with `--init`.
- CI: `fmt -check`, `validate`, `tflint`, `terraform test` (with `mock_provider`), `shellcheck`, symlink/output consistency checks; `go test` (tools/cost, via `make test-go`).
