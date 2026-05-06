use serde::{Deserialize, Deserializer, Serialize, Serializer};

use super::{AcpPermissionBatch, AcpPermissionItem};

#[derive(Debug, Clone, Deserialize, PartialEq)]
struct AcpPermissionBatchDecode {
    batch_id: String,
    #[serde(default)]
    acp_id: Option<String>,
    #[serde(default)]
    managed_agent_id: Option<String>,
    session_id: String,
    requests: Vec<AcpPermissionItem>,
    created_at: String,
    expires_at: String,
}

#[derive(Serialize)]
struct AcpPermissionBatchEncode<'a> {
    batch_id: &'a str,
    acp_id: &'a str,
    managed_agent_id: &'a str,
    managed_agent_family: crate::session::types::ManagedAgentKind,
    session_id: &'a str,
    requests: &'a [AcpPermissionItem],
    created_at: &'a str,
    expires_at: &'a str,
}

impl Serialize for AcpPermissionBatch {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        AcpPermissionBatchEncode {
            batch_id: &self.batch_id,
            acp_id: &self.acp_id,
            managed_agent_id: &self.acp_id,
            managed_agent_family: crate::session::types::ManagedAgentKind::Acp,
            session_id: &self.session_id,
            requests: &self.requests,
            created_at: &self.created_at,
            expires_at: &self.expires_at,
        }
        .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for AcpPermissionBatch {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let decoded = AcpPermissionBatchDecode::deserialize(deserializer)?;
        Ok(Self {
            batch_id: decoded.batch_id,
            acp_id: decoded
                .managed_agent_id
                .or(decoded.acp_id)
                .unwrap_or_default(),
            session_id: decoded.session_id,
            requests: decoded.requests,
            created_at: decoded.created_at,
            expires_at: decoded.expires_at,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::AcpPermissionBatch;

    #[test]
    fn acp_permission_batch_accepts_managed_agent_id_alias() {
        let batch: AcpPermissionBatch = serde_json::from_value(serde_json::json!({
            "batch_id": "batch-1",
            "acp_id": "legacy-acp",
            "managed_agent_id": "acp-1",
            "managed_agent_family": "acp",
            "session_id": "sess-1",
            "created_at": "2026-05-06T00:00:00Z",
            "expires_at": "2026-05-06T00:05:00Z",
            "requests": [],
        }))
        .expect("decode batch");

        assert_eq!(batch.acp_id, "acp-1");
    }

    #[test]
    fn acp_permission_batch_serializes_explicit_identity_fields() {
        let batch = AcpPermissionBatch {
            batch_id: "batch-1".into(),
            acp_id: "acp-1".into(),
            session_id: "sess-1".into(),
            requests: Vec::new(),
            created_at: "2026-05-06T00:00:00Z".into(),
            expires_at: "2026-05-06T00:05:00Z".into(),
        };

        let value = serde_json::to_value(&batch).expect("serialize batch");
        assert_eq!(value["acp_id"], "acp-1");
        assert_eq!(value["managed_agent_id"], "acp-1");
        assert_eq!(value["managed_agent_family"], "acp");
    }
}
