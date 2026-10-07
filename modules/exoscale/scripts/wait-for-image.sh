#!/usr/bin/env bash
# Invoked from image.tf via a local-exec provisioner on the operator's
# machine. Polls IMAGE_URL (the qcow2 the jumphost serves) until it answers, so
# the template is only registered once the file is reachable from the internet.
set -euo pipefail

: "${IMAGE_URL:?IMAGE_URL must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"

# shellcheck source=../../../scripts/lib/poll.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib/poll.sh"

# HEAD, so a poll never pulls the image.
# shellcheck disable=SC2329,SC2317,SC2034  # invoked by poll_until; sets its POLL_* vars
probe() {
  if curl -4 -fsSI -o /dev/null --max-time 10 "$IMAGE_URL" 2>/dev/null; then
    return 0
  fi
  POLL_STATUS=building
  return 1
}

rc=0
poll_until "$TIMEOUT_SECONDS" "$POLL_SECONDS" probe || rc=$?
if [ "$rc" -ne 0 ]; then
  {
    echo "ERROR: the qcow2 image is not served at $IMAGE_URL."
    echo "Either the build failed or port 80 is closed. Check the build log on the jumphost:"
    echo "  ssh <jumphost> tail -f /var/log/elemental-factory.log"
    echo "and that image_import_port_open is true (deploy.sh resets it in pass 1 when the template is created)."
  } >&2
fi
exit "$rc"
