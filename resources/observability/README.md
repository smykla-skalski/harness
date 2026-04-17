# Local Observability Stack

Tempo Explore's Service Graph is the authoritative service map for the local Harness observability stack.
Use the provisioned `Harness Service Map` dashboard as the landing page for supporting RED metrics, then jump into Tempo Explore for the built-in graph and span table.

Tempo metrics-generator owns the `traces_service_graph_*` and `traces_spanmetrics_*` metrics that power the service map.
Alloy still exports the repo's `harness.spanmetrics_*` metrics for the existing custom dashboards, but it should not emit duplicate `traces_service_graph_*` series.

The local Grafana Tempo data source is already provisioned with `serviceMap.datasourceUid: prometheus`, so Tempo Explore can render the built-in Service Graph as soon as Prometheus receives the Tempo-generated metrics.
