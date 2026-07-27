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
    for name in release_binaries() {
        let path = release_dir.join(&name);
        match name.as_str() {
            "harness" => write_fake_harness_binary(&path, version),
            // The same two the installer identifies by `--probe` rather than
            // `--version`; `release_probe_identity` is the source of that split.
            "harness-codex-acp" | "harness-openrouter-agent" => write_fake_shell_tool(
                &path,
                &format!(
                    "#!/bin/sh\nif [ \"$1\" = \"--probe\" ]; then\n  echo '{name}'\n  exit 0\nfi\nexit 1\n"
                ),
            ),
            _ => write_fake_versioned_binary(&path, &name, version),
        }
    }
}

/// Asks the installer's own inventory which binaries a release carries, rather
/// than keeping a second list here. The hardcoded copy this replaces went stale
/// when `harness-panel` was added, and every install test failed on a missing
/// binary the fixture had never heard of.
fn release_binaries() -> Vec<String> {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR"));
    let output = Command::new("/bin/bash")
        .arg("-c")
        .arg("set -eu; . scripts/lib/release-set.sh; printf '%s\\n' \"${HARNESS_RELEASE_BINARIES[@]}\"")
        .current_dir(repo)
        .output()
        .expect("read release inventory");
    assert!(
        output.status.success(),
        "release inventory failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let binaries: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(ToOwned::to_owned)
        .collect();
    assert!(
        binaries.iter().any(|name| name == "harness"),
        "the release inventory must carry the CLI itself, got {binaries:?}"
    );
    binaries
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
