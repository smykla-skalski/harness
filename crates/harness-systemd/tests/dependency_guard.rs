use std::path::Path;
use std::process::Command;

use serde_json::Value;

#[test]
fn cargo_metadata_excludes_daemon_and_root_harness() {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let output = Command::new(env!("CARGO"))
        .args(["metadata", "--format-version", "1", "--manifest-path"])
        .arg(manifest_dir.join("Cargo.toml"))
        .output()
        .expect("run cargo metadata");
    assert!(
        output.status.success(),
        "cargo metadata failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let metadata: Value = serde_json::from_slice(&output.stdout).expect("decode cargo metadata");
    let packages = metadata["packages"].as_array().expect("metadata packages");
    let package = packages
        .iter()
        .find(|package| package["name"] == "harness-systemd")
        .expect("harness-systemd package");
    let package_id = package["id"].as_str().expect("package id");
    let resolve = metadata["resolve"]["nodes"]
        .as_array()
        .expect("metadata resolve nodes");
    let mut pending = vec![package_id.to_string()];
    let mut visited = Vec::new();

    while let Some(id) = pending.pop() {
        if visited.contains(&id) {
            continue;
        }
        visited.push(id.clone());
        let node = resolve
            .iter()
            .find(|node| node["id"] == id)
            .expect("resolved package node");
        pending.extend(
            node["dependencies"]
                .as_array()
                .expect("node dependencies")
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned),
        );
    }

    let forbidden = packages
        .iter()
        .filter(|package| {
            let id = package["id"].as_str().unwrap_or_default();
            visited.iter().any(|visited| visited == id)
                && package["name"]
                    .as_str()
                    .is_some_and(is_forbidden_dependency)
        })
        .filter_map(|package| package["name"].as_str())
        .collect::<Vec<_>>();
    assert!(
        forbidden.is_empty(),
        "harness-systemd dependency graph includes forbidden packages {forbidden:?}"
    );
}

fn is_forbidden_dependency(name: &str) -> bool {
    matches!(
        name,
        "harness" | "harness-daemon" | "harness-mcp" | "k8s-openapi"
    ) || name.starts_with("agent-client-protocol")
        || name.starts_with("axum")
        || name.starts_with("kube")
        || name.starts_with("rmcp")
        || name.starts_with("sqlx")
        || name.starts_with("tokio")
}
