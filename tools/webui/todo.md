# Web UI to-do (alpha)

Open items for the web UI. Design: [ADR 009](../../docs/decisions/009-webui-runner.md),
user guide: [docs/webui.md](../../docs/webui.md).

## Validate

- [ ] SSH and kubeconfig from the container, end to end, on every provider:
  - key file on the volume (`clusters/.home/.ssh/id_ed25519`): generated in the UI
    (default "keep a copy") and pasted on the profile page;
  - SSH agent: Docker Desktop socket (`/run/host-services/ssh-auth.sock`) and a Linux
    `$SSH_AUTH_SOCK` mount, including whether UID 1000 can open the socket;
  - `Download kubeconfig` and `docker exec -it aif clusters/<name>/ssh.sh <host>`;
  - the "no private key" warning on the cluster page disappears once a key is available.

## Features

- [ ] Wizard-only mode: a `Download tfvars` button on the cluster page.
  - A zip of the three layers in the `clusters/` layout (`common-all.tfvars`,
    `common-<provider>.tfvars`, `<name>/terraform.tfvars`) for `cluster.sh`, or one
    merged `terraform.tfvars` for `examples/<provider>/deploy.sh` (`tfvars.Effective`).
  - Leave out the variables `deploy.sh` manages (`managed` in `ui.yaml`).
  - Secrets and password hashes become `REPLACE-ME` unless "include credentials" is
    ticked.
  - Record the repository version (`version.txt`) the files were made for.
  - Optional `WEBUI_MODE=generate`: hide deploy, destroy and jobs; no Terraform or
    cloud CLIs needed, so the same image works as a pure wizard.
- [ ] Price lists baked into the image: fetch the aws, exoscale and vultr catalogs at
  build time and pass them to `tools/cost` as a dated fallback (like the evroc rate
  card), so the cost sidebar works offline and when a pricing API is unreachable.
  Show the catalog date in the sidebar.
