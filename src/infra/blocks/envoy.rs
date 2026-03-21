use std::path::Path;
use std::sync::Arc;

use serde_json::Value;

use super::error::BlockError;
use super::kubernetes::KubernetesOperator;

/// Parameters for an Envoy config dump capture request.
pub struct CaptureRequest<'a> {
    pub namespace: &'a str,
    pub workload: &'a str,
    pub container: &'a str,
    pub admin_host: &'a str,
    pub admin_port: u16,
    pub admin_path: &'a str,
    pub kubeconfig: Option<&'a str>,
}

/// Abstraction over Envoy sidecar introspection.
///
/// Encapsulates kubectl exec + Envoy admin API patterns so command handlers
/// don't need to construct raw exec calls for config dumps, route lookups,
/// or bootstrap extraction.
pub trait ProxyIntrospector: Send + Sync {
    /// Human-readable block name.
    fn name(&self) -> &'static str {
        "envoy"
    }

    /// Capture a full Envoy config dump from a sidecar container.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when the kubectl exec or curl fails.
    fn capture_config_dump(&self, request: &CaptureRequest<'_>) -> Result<String, BlockError>;

    /// Find a route entry matching `match_path` in an Envoy config dump payload.
    ///
    /// Returns `None` when no matching route is found.
    fn find_route(&self, payload: &str, match_path: &str) -> Option<String>;

    /// Extract the bootstrap section from an Envoy config dump,
    /// optionally filtering lines by a grep pattern.
    fn extract_bootstrap(&self, payload: &str, grep: Option<&str>) -> String;
}

/// Production Envoy introspector backed by `KubernetesOperator::run`.
pub struct EnvoyIntrospector {
    kubernetes: Arc<dyn KubernetesOperator>,
}

impl EnvoyIntrospector {
    #[must_use]
    pub fn new(kubernetes: Arc<dyn KubernetesOperator>) -> Self {
        Self { kubernetes }
    }
}

impl ProxyIntrospector for EnvoyIntrospector {
    fn capture_config_dump(&self, request: &CaptureRequest<'_>) -> Result<String, BlockError> {
        let url = format!(
            "http://{}:{}{}",
            request.admin_host, request.admin_port, request.admin_path
        );
        let args = [
            "exec",
            request.workload,
            "-n",
            request.namespace,
            "-c",
            request.container,
            "--",
            "curl",
            "-s",
            &url,
        ];
        let kube_path = request.kubeconfig.map(Path::new);
        let result = self.kubernetes.run(kube_path, &args, &[0])?;
        Ok(result.stdout)
    }

    fn find_route(&self, payload: &str, match_path: &str) -> Option<String> {
        find_route_in_config(payload, match_path)
    }

    fn extract_bootstrap(&self, payload: &str, grep: Option<&str>) -> String {
        filter_bootstrap(payload, grep)
    }
}

fn find_route_in_config(payload: &str, match_path: &str) -> Option<String> {
    let parsed: Value = serde_json::from_str(payload).ok()?;
    let configs = parsed.get("configs")?.as_array()?;
    let keys = ["dynamic_route_configs", "static_route_configs"];

    let route = configs
        .iter()
        .filter_map(Value::as_object)
        .flat_map(|obj| keys.iter().filter_map(move |k| obj.get(*k)?.as_array()))
        .flatten()
        .filter_map(|entry| entry.get("route_config")?.as_object())
        .filter_map(|rc| rc.get("virtual_hosts")?.as_array())
        .flatten()
        .filter_map(|vh| vh.get("routes")?.as_array())
        .flatten()
        .find(|route| {
            route
                .get("match")
                .and_then(Value::as_object)
                .is_some_and(|m| {
                    m.get("path").and_then(Value::as_str) == Some(match_path)
                        || m.get("prefix").and_then(Value::as_str) == Some(match_path)
                })
        })?;

    serde_json::to_string_pretty(route).ok()
}

fn filter_bootstrap(payload: &str, grep: Option<&str>) -> String {
    match grep {
        Some(needle) => payload
            .lines()
            .filter(|line| line.contains(needle))
            .collect::<Vec<_>>()
            .join("\n"),
        None => payload.to_string(),
    }
}

/// Test fake for `ProxyIntrospector`.
#[cfg(test)]
pub struct FakeProxyIntrospector {
    pub config_dump: String,
}

#[cfg(test)]
impl FakeProxyIntrospector {
    #[must_use]
    pub fn new(config_dump: impl Into<String>) -> Self {
        Self {
            config_dump: config_dump.into(),
        }
    }
}

#[cfg(test)]
impl ProxyIntrospector for FakeProxyIntrospector {
    fn capture_config_dump(&self, _request: &CaptureRequest<'_>) -> Result<String, BlockError> {
        Ok(self.config_dump.clone())
    }

    fn find_route(&self, payload: &str, match_path: &str) -> Option<String> {
        find_route_in_config(payload, match_path)
    }

    fn extract_bootstrap(&self, payload: &str, grep: Option<&str>) -> String {
        filter_bootstrap(payload, grep)
    }
}

#[cfg(test)]
#[path = "envoy/tests.rs"]
mod tests;
