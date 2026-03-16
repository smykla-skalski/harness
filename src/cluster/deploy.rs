use serde_json::Value;

use super::spec::{ClusterSpec, HelmSetting};
use super::{parse_helm_settings, parse_string_vec, ClusterMode};

/// Current deploy state, written to current-deploy.json.
#[derive(Debug, Clone, PartialEq)]
pub struct CurrentDeployPayload {
    pub mode: ClusterMode,
    pub updated_at: String,
    pub mode_args: Vec<String>,
    pub helm_settings: Vec<HelmSetting>,
    pub restart_namespaces: Vec<String>,
}

impl CurrentDeployPayload {
    #[must_use]
    pub fn from_spec(spec: &ClusterSpec, updated_at: &str) -> Self {
        Self {
            mode: spec.mode,
            updated_at: updated_at.into(),
            mode_args: spec.mode_args.clone(),
            helm_settings: spec.helm_settings.clone(),
            restart_namespaces: spec.restart_namespaces.clone(),
        }
    }

    /// Parse from a JSON value.
    ///
    /// # Errors
    /// Returns an error if the value is not a valid deploy payload.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let obj = value.as_object().ok_or("expected object")?;
        let mode: ClusterMode = obj
            .get("mode")
            .and_then(Value::as_str)
            .ok_or("missing mode")?
            .parse()?;
        let updated_at = obj
            .get("updated_at")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let mode_args = parse_string_vec(obj.get("mode_args"));
        let helm_settings = parse_helm_settings(obj);
        let restart_namespaces = parse_string_vec(obj.get("restart_namespaces"));
        Ok(Self {
            mode,
            updated_at,
            mode_args,
            helm_settings,
            restart_namespaces,
        })
    }

    #[must_use]
    pub fn matches(&self, spec: &ClusterSpec) -> bool {
        self.mode == spec.mode
            && self.mode_args == spec.mode_args
            && self.helm_settings == spec.helm_settings
    }

    #[must_use]
    pub fn to_json_dict(&self) -> Value {
        let mut map = serde_json::Map::new();
        map.insert("mode".into(), Value::String(self.mode.to_string()));
        map.insert("updated_at".into(), Value::String(self.updated_at.clone()));
        map.insert(
            "mode_args".into(),
            Value::Array(
                self.mode_args
                    .iter()
                    .map(|s| Value::String(s.clone()))
                    .collect(),
            ),
        );
        let hs: Vec<Value> = self
            .helm_settings
            .iter()
            .map(|s| {
                serde_json::json!({
                    "key": s.key,
                    "value": s.value,
                })
            })
            .collect();
        map.insert("helm_settings".into(), Value::Array(hs));
        map.insert(
            "restart_namespaces".into(),
            Value::Array(
                self.restart_namespaces
                    .iter()
                    .map(|s| Value::String(s.clone()))
                    .collect(),
            ),
        );
        Value::Object(map)
    }
}
