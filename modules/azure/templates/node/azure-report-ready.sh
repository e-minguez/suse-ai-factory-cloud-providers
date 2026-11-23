#!/usr/bin/bash
# Reports "Ready" to the Azure WireServer. An image without the Azure agent
# must do it, or the platform reboots the VM after about 20 minutes and fails
# the provisioning. curl and sed only (Microsoft: "Creating generalized images
# without a provisioning agent"). Retries until the platform accepts it.
set -u

WIRE=168.63.129.16
VERSION="x-ms-version: 2012-11-30"

tag() { # tag <name> <xml>: text of the first <name> element
  sed -n "s:.*<$1>\([^<]*\)</$1>.*:\1:p" <<<"$2" | head -n 1
}

for _ in $(seq 1 60); do
  state=$(curl -sf --max-time 10 -H "$VERSION" "http://$WIRE/machine/?comp=goalstate" | tr -d '\r') || state=""
  incarnation=$(tag Incarnation "$state")
  container=$(tag ContainerId "$state")
  instance=$(tag InstanceId "$state")
  if [ -n "$incarnation" ] && [ -n "$container" ] && [ -n "$instance" ]; then
    body="<?xml version=\"1.0\" encoding=\"utf-8\"?><Health xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\"><GoalStateIncarnation>$incarnation</GoalStateIncarnation><Container><ContainerId>$container</ContainerId><RoleInstanceList><Role><InstanceId>$instance</InstanceId><Health><State>Ready</State></Health></Role></RoleInstanceList></Container></Health>"
    if curl -sf --max-time 10 -X POST -H "$VERSION" -H "x-ms-agent-name: elemental" \
      -H "Content-Type: text/xml;charset=utf-8" --data "$body" "http://$WIRE/machine?comp=health" >/dev/null; then
      echo "[azure-report-ready] reported Ready (incarnation $incarnation)"
      exit 0
    fi
  fi
  sleep 15
done

# Not fatal: the node works, only the platform's provisioning state stays open.
echo "[azure-report-ready] WireServer did not accept the report" >&2
exit 0
