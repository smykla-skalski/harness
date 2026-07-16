use std::path::Path;
use std::process::Command;

use serde_json::Value;

#[test]
fn manifest_has_no_root_harness_dependency() {
    let manifest = include_str!("../Cargo.toml");
    assert!(!manifest.lines().any(|line| {
        let line = line.trim_start();
        line.starts_with("harness =") || line.contains("path = \"../..\"")
    }));

    for source in [
        include_str!("../src/lib.rs"),
        include_str!("../src/main.rs"),
        include_str!("../src/app.rs"),
        include_str!("../src/daemon.rs"),
        include_str!("../src/errors.rs"),
        include_str!("../src/runtime.rs"),
    ] {
        assert!(!source.contains("harness::"));
    }
}

#[test]
fn cargo_metadata_confirms_package_isolation() {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let output = Command::new(env!("CARGO"))
        .args([
            "metadata",
            "--format-version",
            "1",
            "--no-deps",
            "--manifest-path",
        ])
        .arg(manifest_dir.join("Cargo.toml"))
        .output()
        .expect("run cargo metadata");
    assert!(
        output.status.success(),
        "cargo metadata failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let metadata: Value = serde_json::from_slice(&output.stdout).expect("decode cargo metadata");
    let package = metadata["packages"]
        .as_array()
        .expect("metadata packages")
        .iter()
        .find(|package| package["name"] == "harness-mcp")
        .expect("harness-mcp package");
    let dependencies = package["dependencies"]
        .as_array()
        .expect("package dependencies");
    assert!(
        dependencies
            .iter()
            .all(|dependency| dependency["name"] != "harness"),
        "harness-mcp metadata still includes the root harness package"
    );
}
