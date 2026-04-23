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
DASHBOARDS="harness-investigation-cockpit claude-code-global harness-host-machine harness-host-processes harness-daemon-transport harness-monitor-client harness-runtime-execution harness-sqlite-forensics harness-service-map"

for uid in $DASHBOARDS; do
  if curl -sf -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/dashboards/uid/$uid" > /dev/null; then
    curl -sf -X POST -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/user/stars/dashboard/uid/$uid" > /dev/null
    echo "Starred: $uid"
  else
    echo "Dashboard not found: $uid"
  fi
done

echo "Done starring dashboards"
