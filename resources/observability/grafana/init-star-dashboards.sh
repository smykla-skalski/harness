#!/bin/sh
# Stars all harness dashboards for admin user after Grafana is ready

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_USER="${GF_SECURITY_ADMIN_USER:-admin}"
GRAFANA_PASS="${GF_SECURITY_ADMIN_PASSWORD:-harness}"

# wait for grafana to be ready
echo "Waiting for Grafana to be ready..."
until curl -sf "$GRAFANA_URL/api/health" > /dev/null 2>&1; do
  sleep 1
done
echo "Grafana is ready"

# star each dashboard
DASHBOARDS="harness-investigation-cockpit harness-host-machine harness-host-processes harness-daemon-transport harness-monitor-client harness-runtime-execution harness-sqlite-forensics harness-service-map"

for uid in $DASHBOARDS; do
  # get dashboard id from uid
  id=$(curl -sf -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/dashboards/uid/$uid" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  if [ -n "$id" ]; then
    curl -sf -X POST -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/user/stars/dashboard/$id" > /dev/null
    echo "Starred: $uid (id=$id)"
  else
    echo "Dashboard not found: $uid"
  fi
done

echo "Done starring dashboards"
