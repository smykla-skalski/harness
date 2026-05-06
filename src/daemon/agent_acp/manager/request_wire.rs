use serde::{Deserialize, Deserializer, Serialize, Serializer};

use super::{AcpAgentStartRequest, default_acp_role};

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
struct AcpAgentStartRequestDecode {
    #[serde(default)]
    descriptor_id: Option<String>,
    #[serde(default)]
    agent: Option<String>,
    #[serde(default)]
    agent_id: Option<String>,
    #[serde(default = "default_acp_role")]
    role: crate::session::types::SessionRole,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fallback_role: Option<crate::session::types::SessionRole>,
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
    #[serde(default)]
    record_permissions: bool,
}

#[derive(Serialize)]
struct AcpAgentStartRequestEncode<'a> {
    descriptor_id: &'a str,
    agent: &'a str,
    role: crate::session::types::SessionRole,
    #[serde(skip_serializing_if = "Option::is_none")]
    fallback_role: Option<crate::session::types::SessionRole>,
    capabilities: &'a [String],
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    project_dir: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    persona: Option<&'a str>,
    record_permissions: bool,
}

impl Serialize for AcpAgentStartRequest {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        AcpAgentStartRequestEncode {
            descriptor_id: &self.agent,
            agent: &self.agent,
            role: self.role,
            fallback_role: self.fallback_role,
            capabilities: &self.capabilities,
            name: self.name.as_deref(),
            prompt: self.prompt.as_deref(),
            project_dir: self.project_dir.as_deref(),
            persona: self.persona.as_deref(),
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
        Ok(Self {
            agent: decoded
                .descriptor_id
                .or(decoded.agent)
                .or(decoded.agent_id)
                .unwrap_or_default(),
            role: decoded.role,
            fallback_role: decoded.fallback_role,
            capabilities: decoded.capabilities,
            name: decoded.name,
            prompt: decoded.prompt,
            project_dir: decoded.project_dir,
            persona: decoded.persona,
            record_permissions: decoded.record_permissions,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::AcpAgentStartRequest;

    #[test]
    fn acp_start_request_accepts_descriptor_id_alias() {
        let request: AcpAgentStartRequest = serde_json::from_value(serde_json::json!({
            "descriptor_id": "copilot",
            "role": "reviewer",
            "record_permissions": true
        }))
        .expect("decode request");

        assert_eq!(request.agent, "copilot");
        assert_eq!(request.role, crate::session::types::SessionRole::Reviewer);
        assert!(request.record_permissions);
    }

    #[test]
    fn acp_start_request_serializes_descriptor_and_legacy_agent_fields() {
        let request = AcpAgentStartRequest {
            agent: "copilot".into(),
            role: crate::session::types::SessionRole::Reviewer,
            fallback_role: Some(crate::session::types::SessionRole::Observer),
            capabilities: vec!["fs.read".into()],
            name: Some("Copilot Reviewer".into()),
            prompt: Some("Run it".into()),
            project_dir: Some("/tmp/project".into()),
            persona: Some("reviewer".into()),
            record_permissions: true,
        };

        let value = serde_json::to_value(&request).expect("serialize request");
        assert_eq!(value["descriptor_id"], "copilot");
        assert_eq!(value["agent"], "copilot");
        assert_eq!(value["role"], "reviewer");
        assert_eq!(value["fallback_role"], "observer");
        assert_eq!(value["record_permissions"], true);
    }
}
