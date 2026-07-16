use std::collections::BTreeMap;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

pub(super) fn write_fake_harness_binary(path: &Path, version: &str) {
    std::fs::create_dir_all(path.parent().expect("binary parent")).expect("create binary dir");
    std::fs::write(
        path,
        format!(
            "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  echo 'harness {version}'\n  exit 0\nfi\nif [ \"$1\" = \"--help\" ]; then\n  echo 'Harness CLI'\n  exit 0\nfi\nexit 0\n"
        ),
    )
    .expect("write fake harness");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
        .expect("chmod fake harness");
}

pub(super) fn write_fake_shell_tool(path: &Path, body: &str) {
    std::fs::create_dir_all(path.parent().expect("binary parent")).expect("create binary dir");
    std::fs::write(path, body).expect("write fake shell tool");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
        .expect("chmod fake shell tool");
}

pub(super) fn write_fake_harness_release_set(target_dir: &Path, version: &str) {
    let release_dir = target_dir.join("release");
    write_fake_harness_binary(&release_dir.join("harness"), version);

    for name in [
        "harness-daemon",
        "harness-bridge",
        "harness-mcp",
        "harness-hook",
    ] {
        write_fake_versioned_binary(&release_dir.join(name), name, version);
    }
    for name in ["harness-codex-acp", "harness-openrouter-agent"] {
        let body = format!(
            "#!/bin/sh\nif [ \"$1\" = \"--probe\" ]; then\n  echo '{name}'\n  exit 0\nfi\nexit 1\n"
        );
        write_fake_shell_tool(&release_dir.join(name), &body);
    }
}

fn write_fake_versioned_binary(path: &Path, name: &str, version: &str) {
    write_fake_shell_tool(
        path,
        &format!(
            "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  echo '{name} {version}'\n  exit 0\nfi\nexit 0\n"
        ),
    );
}

pub(super) fn run_harness_version(path: &Path) -> String {
    let output = Command::new(path)
        .arg("--version")
        .output()
        .expect("run harness --version");
    assert!(
        output.status.success(),
        "version command failed for {}: stdout={} stderr={}",
        path.display(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

pub(super) fn parse_env_output(output: &[u8]) -> BTreeMap<String, String> {
    String::from_utf8_lossy(output)
        .lines()
        .filter_map(|line| line.split_once('='))
        .map(|(key, value)| (key.to_string(), value.to_string()))
        .collect()
}
