use reqwest::Method;
use serde_json::{Value, json};

use super::DaemonHttpClient;

pub(super) fn reject_pending_permissions(
    http: &DaemonHttpClient,
    managed_agent_id: &str,
) -> Result<(), String> {
    let detail = http.request_json(
        Method::GET,
        &format!("/v1/managed-agents/{managed_agent_id}"),
        None,
    )?;
    for batch_id in pending_permission_batch_ids(&detail) {
        http.request_json(
            Method::POST,
            &format!("/v1/managed-agents/{managed_agent_id}/permission-batches/{batch_id}"),
            Some(json!({ "decision": "deny_all" })),
        )?;
    }
    Ok(())
}

fn pending_permission_batch_ids(detail: &Value) -> Vec<&str> {
    detail
        .pointer("/snapshot/pending_permission_batches")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|batch| batch["batch_id"].as_str())
        .collect()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    #[test]
    fn pending_permission_batch_ids_reads_acp_detail_snapshot() {
        let detail = json!({
            "kind": "acp",
            "snapshot": {
                "pending_permission_batches": [
                    { "batch_id": "batch-1" },
                    { "batch_id": "batch-2" }
                ]
            }
        });

        assert_eq!(
            super::pending_permission_batch_ids(&detail),
            ["batch-1", "batch-2"]
        );
    }
}
