# shellcheck shell=bash
# qemu-img ships in qemu-tools; extra_packages needs package name == command.
zypper -n install qemu-tools || log "zypper install qemu-tools reported a non-zero exit, continuing"
if ! command -v qemu-img >/dev/null; then
  log "ERROR: qemu-img is not installed after zypper install qemu-tools"
  exit 1
fi
