use std::fs;

use super::{BuildInfo, parse_version_script_output, resolve_build_info};

#[test]
fn build_info_env() {
    let info = BuildInfo {
        version: "1.2.3".into(),
    };
    let env = info.env();
    assert_eq!(env.get("BUILD_INFO_VERSION").unwrap(), "1.2.3");
}

#[test]
fn parse_version_script_output_uses_first_field() {
    let output = b"0.0.0-preview.vabc123 v2.13.0-444-gabc123 abc123 local-build master\n";
    assert_eq!(
        parse_version_script_output(output).as_deref(),
        Some("0.0.0-preview.vabc123")
    );
}

#[cfg(unix)]
#[test]
fn resolve_build_info_uses_first_version_field_from_script() {
    use std::os::unix::fs::PermissionsExt as _;

    let tmp = tempfile::tempdir().unwrap();
    let script_dir = tmp.path().join("tools/releases");
    fs::create_dir_all(&script_dir).unwrap();
    let script_path = script_dir.join("version.sh");
    fs::write(
        &script_path,
        "#!/usr/bin/env bash\nprintf '%s\\n' '0.0.0-preview.vabc123 v2.13.0-444-gabc123 abc123 local-build master'\n",
    )
    .unwrap();
    let mut permissions = fs::metadata(&script_path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&script_path, permissions).unwrap();

    let info = resolve_build_info(tmp.path()).unwrap();
    assert_eq!(info.version, "0.0.0-preview.vabc123");
}
