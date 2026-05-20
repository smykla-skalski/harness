use serde::de::Error as DeError;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use super::{AcpPermissionBatch, AcpPermissionItem};
use crate::session::types::ManagedAgentKind;

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct AcpPermissionBatchDecode {
    batch_id: String,
    managed_agent_id: String,
    managed_agent_family: ManagedAgentKind,
    session_id: String,
    requests: Vec<AcpPermissionItem>,
    created_at: String,
    expires_at: String,
}

#[derive(Serialize)]
struct AcpPermissionBatchEncode<'a> {
    batch_id: &'a str,
    managed_agent_id: &'a str,
    managed_agent_family: ManagedAgentKind,
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
            managed_agent_id: &self.acp_id,
            managed_agent_family: ManagedAgentKind::Acp,
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
        validate_permission_family::<D::Error>(decoded.managed_agent_family)?;
        Ok(Self {
            batch_id: decoded.batch_id,
            acp_id: decoded.managed_agent_id,
            session_id: decoded.session_id,
            requests: decoded.requests,
            created_at: decoded.created_at,
            expires_at: decoded.expires_at,
        })
    }
}

fn validate_permission_family<E>(managed_agent_family: ManagedAgentKind) -> Result<(), E>
where
    E: DeError,
{
    match managed_agent_family {
        ManagedAgentKind::Acp => Ok(()),
        other => Err(E::custom(format!(
            "managed_agent_family must be 'acp', got '{other:?}'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::AcpPermissionBatch;

    #[test]
    fn acp_permission_batch_decodes_canonical_identity_fields() {
        let batch: AcpPermissionBatch = serde_json::from_value(serde_json::json!({
            "batch_id": "batch-1",
            "managed_agent_id": "acp-1",
            "managed_agent_family": "acp",
            "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
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
            session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
            requests: Vec::new(),
            created_at: "2026-05-06T00:00:00Z".into(),
            expires_at: "2026-05-06T00:05:00Z".into(),
        };

        let value = serde_json::to_value(&batch).expect("serialize batch");
        assert_eq!(value["managed_agent_id"], "acp-1");
        assert_eq!(value["managed_agent_family"], "acp");
        assert!(value.get("acp_id").is_none());
    }

    #[test]
    fn acp_permission_batch_rejects_missing_managed_agent_family() {
        let error = serde_json::from_value::<AcpPermissionBatch>(serde_json::json!({
            "batch_id": "batch-1",
            "managed_agent_id": "acp-1",
            "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            "created_at": "2026-05-06T00:00:00Z",
            "expires_at": "2026-05-06T00:05:00Z",
            "requests": [],
        }))
        .expect_err("missing family should fail");

        assert!(
            error.to_string().contains("managed_agent_family"),
            "expected managed_agent_family error, got {error}"
        );
    }

    #[test]
    fn acp_permission_batch_rejects_non_acp_family() {
        let error = serde_json::from_value::<AcpPermissionBatch>(serde_json::json!({
            "batch_id": "batch-1",
            "managed_agent_id": "acp-1",
            "managed_agent_family": "tui",
            "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            "created_at": "2026-05-06T00:00:00Z",
            "expires_at": "2026-05-06T00:05:00Z",
            "requests": [],
        }))
        .expect_err("wrong family should fail");

        assert!(
            error
                .to_string()
                .contains("managed_agent_family must be 'acp'"),
            "expected acp family error, got {error}"
        );
    }
}
