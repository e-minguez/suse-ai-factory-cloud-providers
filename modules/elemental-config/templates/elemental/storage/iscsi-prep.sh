#!/usr/bin/env bash
# Seeds the /etc state open-iSCSI needs and starts iscsid. Run at every boot
# by iscsi-prep.service; the suse-storage sysext ships /usr only.
# see docs/decisions/001-elemental-config-rationale.md
set -euo pipefail

log() { echo "iscsi-prep: $*"; }

for _ in $(seq 1 30); do
  [ -x /usr/sbin/iscsid ] && break
  sleep 2
done

if [ ! -x /usr/sbin/iscsid ]; then
  log "no /usr/sbin/iscsid after 60s, extension not merged; nothing to do"
  exit 0
fi

mkdir -p /etc/iscsi

# Unique per node, so it cannot be baked into the shared image.
if [ ! -s /etc/iscsi/initiatorname.iscsi ]; then
  if command -v iscsi-iname >/dev/null 2>&1; then
    initiator_name="$(iscsi-iname)"
  else
    initiator_name="iqn.2016-04.com.open-iscsi:$(hostname)"
  fi
  printf 'InitiatorName=%s\n' "$initiator_name" >/etc/iscsi/initiatorname.iscsi
  chmod 0600 /etc/iscsi/initiatorname.iscsi
  log "generated InitiatorName=$initiator_name"
fi

# Prefer a stock config shipped by the extension, else open-iscsi defaults.
if [ ! -s /etc/iscsi/iscsid.conf ]; then
  stock_conf=""
  for candidate in \
    /usr/etc/iscsi/iscsid.conf \
    /usr/share/open-iscsi/iscsid.conf \
    /usr/share/doc/packages/open-iscsi/iscsid.conf; do
    if [ -f "$candidate" ]; then
      stock_conf="$candidate"
      break
    fi
  done

  if [ -n "$stock_conf" ]; then
    cp "$stock_conf" /etc/iscsi/iscsid.conf
    log "seeded /etc/iscsi/iscsid.conf from $stock_conf"
  else
    cat >/etc/iscsi/iscsid.conf <<'CONF'
iscsid.startup = /bin/systemctl start iscsid.socket
node.startup = manual
node.session.timeo.replacement_timeout = 120
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout = 5
CONF
    log "wrote fallback /etc/iscsi/iscsid.conf"
  fi
  chmod 0600 /etc/iscsi/iscsid.conf
fi

# --no-block: this unit must not wait on a job ordered after itself.
systemctl start --no-block iscsid.service
log "iscsid start requested"
