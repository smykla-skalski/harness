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
mod tests {
    use super::*;

    #[test]
    fn fake_proxy_returns_canned_dump() {
        let fake = FakeProxyIntrospector::new("{\"configs\":[]}");
        let request = CaptureRequest {
            namespace: "ns",
            workload: "deploy/x",
            container: "sidecar",
            admin_host: "127.0.0.1",
            admin_port: 9901,
            admin_path: "/config_dump",
            kubeconfig: None,
        };
        let result = fake.capture_config_dump(&request).expect("should succeed");
        assert_eq!(result, "{\"configs\":[]}");
    }

    #[test]
    fn extract_bootstrap_filters_by_grep() {
        let fake = FakeProxyIntrospector::new("");
        let payload = "line one\nbootstrap: true\nline three\nbootstrap: false";
        let filtered = fake.extract_bootstrap(payload, Some("bootstrap"));
        assert_eq!(filtered, "bootstrap: true\nbootstrap: false");
    }

    #[test]
    fn extract_bootstrap_returns_full_without_grep() {
        let fake = FakeProxyIntrospector::new("");
        let payload = "line one\nline two";
        let result = fake.extract_bootstrap(payload, None);
        assert_eq!(result, payload);
    }

    #[test]
    fn find_route_returns_none_for_empty_config() {
        let fake = FakeProxyIntrospector::new("");
        assert!(fake.find_route("{\"configs\":[]}", "/test").is_none());
    }

    #[test]
    fn proxy_introspector_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<EnvoyIntrospector>();
        assert_send_sync::<FakeProxyIntrospector>();
    }
}
