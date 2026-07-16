use serde::de::Error as DeError;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use super::models::{AcpAgentStartRequest, default_acp_role};
use crate::session::SessionRole;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct AcpAgentStartRequestDecode {
    descriptor_id: String,
    #[serde(default = "default_acp_role")]
    role: SessionRole,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fallback_role: Option<SessionRole>,
    #[serde(default)]
    capabilities: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    project_dir: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    persona: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    task_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    board_item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    workflow_execution_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    effort: Option<String>,
    #[serde(default)]
    allow_custom_model: bool,
    #[serde(default)]
    record_permissions: bool,
}

#[derive(Serialize)]
struct AcpAgentStartRequestEncode<'a> {
    descriptor_id: &'a str,
    role: SessionRole,
    #[serde(skip_serializing_if = "Option::is_none")]
    fallback_role: Option<SessionRole>,
    capabilities: &'a [String],
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    project_dir: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    persona: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    task_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    board_item_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    workflow_execution_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    effort: Option<&'a str>,
    allow_custom_model: bool,
    record_permissions: bool,
}

impl Serialize for AcpAgentStartRequest {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        AcpAgentStartRequestEncode {
            descriptor_id: &self.agent,
            role: self.role,
            fallback_role: self.fallback_role,
            capabilities: &self.capabilities,
            name: self.name.as_deref(),
            prompt: self.prompt.as_deref(),
            project_dir: self.project_dir.as_deref(),
            persona: self.persona.as_deref(),
            task_id: self.task_id.as_deref(),
            board_item_id: self.board_item_id.as_deref(),
            workflow_execution_id: self.workflow_execution_id.as_deref(),
            model: self.model.as_deref(),
            effort: self.effort.as_deref(),
            allow_custom_model: self.allow_custom_model,
            record_permissions: self.record_permissions,
        }
        .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for AcpAgentStartRequest {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let decoded = AcpAgentStartRequestDecode::deserialize(deserializer)?;
        if decoded.descriptor_id.trim().is_empty() {
            return Err(DeError::custom("descriptor_id must not be empty"));
        }
        Ok(Self {
            agent: decoded.descriptor_id,
            role: decoded.role,
            fallback_role: decoded.fallback_role,
            capabilities: decoded.capabilities,
            name: decoded.name,
            prompt: decoded.prompt,
            project_dir: decoded.project_dir,
            persona: decoded.persona,
            task_id: decoded.task_id,
            board_item_id: decoded.board_item_id,
            workflow_execution_id: decoded.workflow_execution_id,
            model: decoded.model,
            effort: decoded.effort,
            allow_custom_model: decoded.allow_custom_model,
            record_permissions: decoded.record_permissions,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::AcpAgentStartRequest;

    #[test]
    fn acp_start_request_decodes_canonical_descriptor_id() {
        let request: AcpAgentStartRequest = serde_json::from_value(serde_json::json!({
            "descriptor_id": "copilot",
            "role": "reviewer",
            "task_id": "task-1",
            "board_item_id": "board-item-1",
            "workflow_execution_id": "workflow-1",
            "model": "gpt-5.4",
            "effort": "high",
            "allow_custom_model": true,
            "record_permissions": true
        }))
        .expect("decode request");

        assert_eq!(request.agent, "copilot");
        assert_eq!(request.role, crate::session::SessionRole::Reviewer);
        assert_eq!(request.task_id.as_deref(), Some("task-1"));
        assert_eq!(request.board_item_id.as_deref(), Some("board-item-1"));
        assert_eq!(request.workflow_execution_id.as_deref(), Some("workflow-1"));
        assert_eq!(request.model.as_deref(), Some("gpt-5.4"));
        assert_eq!(request.effort.as_deref(), Some("high"));
        assert!(request.allow_custom_model);
        assert!(request.record_permissions);
    }

    #[test]
    fn acp_start_request_rejects_missing_descriptor_id() {
        let error = serde_json::from_value::<AcpAgentStartRequest>(serde_json::json!({
            "role": "reviewer",
        }))
        .expect_err("missing descriptor_id should fail");

        assert!(
            error.to_string().contains("descriptor_id"),
            "expected descriptor_id error, got {error}"
        );
    }

    #[test]
    fn acp_start_request_rejects_legacy_alias_fields() {
        let error = serde_json::from_value::<AcpAgentStartRequest>(serde_json::json!({
            "descriptor_id": "copilot",
            "agent": "copilot",
        }))
        .expect_err("legacy alias should fail");

        assert!(
            error.to_string().contains("unknown field"),
            "expected unknown field error, got {error}"
        );
    }

    #[test]
    fn acp_start_request_serializes_canonical_descriptor_field() {
        let request = AcpAgentStartRequest {
            agent: "copilot".into(),
            role: crate::session::SessionRole::Reviewer,
            fallback_role: Some(crate::session::SessionRole::Observer),
            capabilities: vec!["fs.read".into()],
            name: Some("Copilot Reviewer".into()),
            prompt: Some("Run it".into()),
            project_dir: Some("/tmp/project".into()),
            persona: Some("reviewer".into()),
            task_id: Some("task-1".into()),
            board_item_id: Some("board-item-1".into()),
            workflow_execution_id: Some("workflow-1".into()),
            model: Some("gpt-5.4".into()),
            effort: Some("high".into()),
            allow_custom_model: true,
            record_permissions: true,
        };

        let value = serde_json::to_value(&request).expect("serialize request");
        assert_eq!(value["descriptor_id"], "copilot");
        assert!(value.get("agent").is_none());
        assert_eq!(value["role"], "reviewer");
        assert_eq!(value["fallback_role"], "observer");
        assert_eq!(value["task_id"], "task-1");
        assert_eq!(value["board_item_id"], "board-item-1");
        assert_eq!(value["workflow_execution_id"], "workflow-1");
        assert_eq!(value["model"], "gpt-5.4");
        assert_eq!(value["effort"], "high");
        assert_eq!(value["allow_custom_model"], true);
        assert_eq!(value["record_permissions"], true);
    }
}
