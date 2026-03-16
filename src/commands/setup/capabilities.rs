use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};

fn platforms() -> Value {
    serde_json::json!([
        {
            "name": "kubernetes",
            "aliases": ["k8s"],
            "description": "k3d-based local Kubernetes clusters with Helm-deployed Kuma"
        },
        {
            "name": "universal",
            "aliases": [],
            "description": "Docker-based universal mode with CP containers and dataplane tokens"
        }
    ])
}

fn cluster_topologies() -> Value {
    serde_json::json!([
        {
            "mode": "single-zone",
            "profiles": ["single-zone", "single-zone-universal"],
            "description": "single CP with one cluster or one Docker CP container"
        },
        {
            "mode": "multi-zone",
            "profiles": ["multi-zone", "multi-zone-universal"],
            "description": "global CP with one or two zone CPs (k3d or Docker)"
        }
    ])
}

fn features() -> Value {
    serde_json::json!({
        "gateway_api": {
            "available": true,
            "description": "install Gateway API CRDs from go.mod-pinned version",
            "command": "harness gateway"
        },
        "envoy_admin": {
            "available": true,
            "description": "capture and inspect Envoy config dumps, routes, listeners, clusters, bootstrap",
            "commands": ["harness envoy capture", "harness envoy route-body", "harness envoy bootstrap"]
        },
        "manifest_apply": {
            "available": true,
            "description": "tracked manifest application with validation, copy, and logging",
            "command": "harness apply"
        },
        "manifest_validate": {
            "available": true,
            "description": "server-side dry-run validation before apply",
            "command": "harness validate"
        },
        "state_capture": {
            "available": true,
            "description": "snapshot cluster pod state as timestamped artifacts",
            "command": "harness capture"
        },
        "tracked_recording": {
            "available": true,
            "description": "record arbitrary shell commands with stdout capture and audit trail",
            "commands": ["harness record", "harness run"]
        },
        "dataplane_tokens": {
            "available": true,
            "description": "generate dataplane/ingress/egress tokens from CP REST API or kumactl",
            "command": "harness token",
            "platforms": ["universal"]
        },
        "service_containers": {
            "available": true,
            "description": "manage test service Docker containers with dataplane sidecars",
            "command": "harness service",
            "platforms": ["universal"]
        },
        "transparent_proxy": {
            "available": true,
            "description": "install transparent proxy on universal service containers",
            "platforms": ["universal"]
        },
        "kumactl": {
            "available": true,
            "description": "find or build kumactl from local repo checkout",
            "commands": ["harness kumactl find", "harness kumactl build"]
        },
        "json_diff": {
            "available": true,
            "description": "key-by-key JSON diff between two payloads",
            "command": "harness diff"
        },
        "run_lifecycle": {
            "available": true,
            "description": "full run lifecycle: init, preflight, execute, report, closeout",
            "commands": [
                "harness init", "harness preflight", "harness runner-state",
                "harness report group", "harness report check", "harness closeout"
            ]
        },
        "helm_settings": {
            "available": true,
            "description": "pass custom Helm values during cluster bootstrap",
            "platforms": ["kubernetes"]
        },
        "namespace_restart": {
            "available": true,
            "description": "restart workloads in specified namespaces after deployment changes",
            "platforms": ["kubernetes"]
        }
    })
}

fn authoring() -> Value {
    serde_json::json!({
        "available": true,
        "description": "interactive suite authoring with discovery workers and approval gates",
        "commands": [
            "harness authoring-begin", "harness authoring-save", "harness authoring-show",
            "harness authoring-reset", "harness authoring-validate", "harness approval-begin"
        ]
    })
}

/// Report harness capabilities as structured JSON for skill planning.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn capabilities() -> Result<i32, CliError> {
    let caps = serde_json::json!({
        "platforms": platforms(),
        "cluster_topologies": cluster_topologies(),
        "features": features(),
        "authoring": authoring(),
    });
    let output = serde_json::to_string_pretty(&caps)
        .map_err(|e| CliErrorKind::io(format!("json serialize: {e}")))?;
    println!("{output}");
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_returns_zero() {
        assert_eq!(capabilities().unwrap(), 0);
    }

    #[test]
    fn output_contains_expected_keys() {
        let caps = serde_json::json!({
            "platforms": platforms(),
            "cluster_topologies": cluster_topologies(),
            "features": features(),
            "authoring": authoring(),
        });
        assert!(caps["platforms"].is_array());
        assert!(caps["cluster_topologies"].is_array());
        assert!(caps["features"].is_object());
        assert!(caps["authoring"].is_object());
    }

    #[test]
    fn platforms_lists_both() {
        let p = platforms();
        let arr = p.as_array().unwrap();
        let names: Vec<&str> = arr
            .iter()
            .filter_map(|v| v["name"].as_str())
            .collect();
        assert!(names.contains(&"kubernetes"));
        assert!(names.contains(&"universal"));
    }

    #[test]
    fn features_include_universal_only_items() {
        let f = features();
        let tokens = &f["dataplane_tokens"];
        assert_eq!(tokens["available"], true);
        let plats = tokens["platforms"].as_array().unwrap();
        assert_eq!(plats.len(), 1);
        assert_eq!(plats[0].as_str().unwrap(), "universal");
    }
}
