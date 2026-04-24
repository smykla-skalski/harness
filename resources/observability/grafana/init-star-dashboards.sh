#!/bin/sh
# Stars all harness dashboards for admin user and sets the org home dashboard after Grafana is ready

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_USER="${GF_SECURITY_ADMIN_USER:-admin}"
GRAFANA_PASS="${GF_SECURITY_ADMIN_PASSWORD:-harness}"
HOME_DASHBOARD_UID="${HOME_DASHBOARD_UID:-ai-agents}"

# wait for grafana to be ready
echo "Waiting for Grafana to be ready..."
until curl -sf "$GRAFANA_URL/api/health" > /dev/null 2>&1; do
  sleep 1
done
echo "Grafana is ready"

# star each dashboard
DASHBOARDS="harness-investigation-cockpit ai-agents harness-host-machine harness-host-processes harness-daemon-transport harness-monitor-client harness-runtime-execution harness-sqlite-forensics harness-service-map"

for uid in $DASHBOARDS; do
  if curl -sf -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/dashboards/uid/$uid" > /dev/null; then
    curl -sf -X POST -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/user/stars/dashboard/uid/$uid" > /dev/null
    echo "Starred: $uid"
  else
    echo "Dashboard not found: $uid"
  fi
done

if curl -sf -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/dashboards/uid/$HOME_DASHBOARD_UID" > /dev/null; then
  curl -sf -X PATCH \
    -u "$GRAFANA_USER:$GRAFANA_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"homeDashboardUID\":\"$HOME_DASHBOARD_UID\"}" \
    "$GRAFANA_URL/api/org/preferences" > /dev/null
  echo "Set org home dashboard: $HOME_DASHBOARD_UID"
else
  echo "Home dashboard not found: $HOME_DASHBOARD_UID"
fi

echo "Done starring dashboards"
