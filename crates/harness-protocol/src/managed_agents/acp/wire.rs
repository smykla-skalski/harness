use serde::de::Error as DeError;
use serde::{Deserialize, Deserializer};

use super::models::BridgeAcpStartRequest;

#[derive(Deserialize)]
struct BridgeAcpStartRequestDecode {
    session_id: String,
    request: serde_json::Value,
    #[serde(default)]
    disable_pooling: bool,
    #[serde(default)]
    openrouter_token: Option<String>,
}

impl<'de> Deserialize<'de> for BridgeAcpStartRequest {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let mut decoded = BridgeAcpStartRequestDecode::deserialize(deserializer)?;
        if let Some(request) = decoded.request.as_object_mut()
            && !request.contains_key("descriptor_id")
            && let Some(agent) = request.remove("agent")
        {
            request.insert("descriptor_id".to_string(), agent);
        }
        let request = serde_json::from_value(decoded.request).map_err(D::Error::custom)?;
        Ok(Self {
            session_id: decoded.session_id,
            request,
            disable_pooling: decoded.disable_pooling,
            openrouter_token: decoded.openrouter_token,
        })
    }
}

#[cfg(test)]
use super::models::{
    AcpAgentInspectSnapshot, AcpAgentSnapshot, AcpAgentStartRequest, AcpPermissionBatch,
    AcpPermissionItem,
};

#[cfg(test)]
mod tests;
