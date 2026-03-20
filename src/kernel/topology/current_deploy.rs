use serde_json::Value;

use super::{ClusterMode, ClusterSpec};

#[derive(Debug, Clone, PartialEq)]
struct CurrentDeployPayload {
    mode: ClusterMode,
    updated_at: String,
    mode_args: Vec<String>,
    helm_settings: Vec<super::HelmSetting>,
    restart_namespaces: Vec<String>,
}

impl CurrentDeployPayload {
    fn from_spec(spec: &ClusterSpec, updated_at: &str) -> Self {
        Self {
            mode: spec.mode,
            updated_at: updated_at.into(),
            mode_args: spec.mode_args.clone(),
            helm_settings: spec.helm_settings.clone(),
            restart_namespaces: spec.restart_namespaces.clone(),
        }
    }

    fn from_value(value: &Value) -> Result<Self, String> {
        let obj = value.as_object().ok_or("expected object")?;
        Ok(Self {
            mode: obj
                .get("mode")
                .and_then(Value::as_str)
                .ok_or("missing mode")?
                .parse()?,
            updated_at: obj
                .get("updated_at")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            mode_args: super::parsing::parse_string_vec(obj.get("mode_args")),
            helm_settings: super::parsing::parse_helm_settings(obj),
            restart_namespaces: super::parsing::parse_string_vec(obj.get("restart_namespaces")),
        })
    }

    fn matches(&self, spec: &ClusterSpec) -> bool {
        self.mode == spec.mode
            && self.mode_args == spec.mode_args
            && self.helm_settings == spec.helm_settings
    }

    fn to_json_dict(&self) -> Value {
        let mut map = serde_json::Map::new();
        map.insert("mode".into(), Value::String(self.mode.to_string()));
        map.insert("updated_at".into(), Value::String(self.updated_at.clone()));
        map.insert(
            "mode_args".into(),
            Value::Array(
                self.mode_args
                    .iter()
                    .map(|item| Value::String(item.clone()))
                    .collect(),
            ),
        );
        map.insert(
            "helm_settings".into(),
            Value::Array(
                self.helm_settings
                    .iter()
                    .map(|setting| {
                        serde_json::json!({
                            "key": setting.key,
                            "value": setting.value,
                        })
                    })
                    .collect(),
            ),
        );
        map.insert(
            "restart_namespaces".into(),
            Value::Array(
                self.restart_namespaces
                    .iter()
                    .map(|item| Value::String(item.clone()))
                    .collect(),
            ),
        );
        Value::Object(map)
    }
}

pub(crate) fn to_json_dict(spec: &ClusterSpec, updated_at: &str) -> Value {
    CurrentDeployPayload::from_spec(spec, updated_at).to_json_dict()
}

pub(crate) fn matches_deploy_dict(spec: &ClusterSpec, payload: &Value) -> bool {
    CurrentDeployPayload::from_value(payload).is_ok_and(|deploy| deploy.matches(spec))
}
