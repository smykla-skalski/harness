// Policy drift integration test.
//
// Catches divergence between the free-function write-surface policy
// (`agents::policy::evaluate_write`) and the TUI hook handler
// (`hooks::guard_write`). Both call sites must produce identical decisions
// for the same inputs; when they diverge, either the policy needs updating
// or the hook needs refactoring to call the shared function.
//
// Fixture set: the nasty-input cases that tend to expose policy drift:
// - `..` traversal
// - symlink to outside surface
// - denied binary inside allowed dir
// - file inside denied dir
// - canonical-vs-non-canonical paths
//
// When ACP `Client::write_text_file` lands (Chunk 4), extend this test to
// also drive the ACP path through the same fixtures.

use std::collections::BTreeSet;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

use harness::agents::policy::{DeniedBinaries, WriteDecision, WriteSurfaceContext, evaluate_write};
use harness::hooks::guard_write;
use harness::hooks::hook_result::Decision;

use super::helpers::*;

/// Fixture case for drift testing.
struct DriftFixture {
    name: &'static str,
    /// Path to test (relative to run_dir unless absolute).
    path: PathBuf,
    /// Whether the policy should allow or deny.
    expected_allow: bool,
    /// Extra setup (symlinks, etc.) if needed.
    setup: Option<Box<dyn Fn(&Path, &Path) + Send + Sync>>,
}

fn denied_binaries() -> DeniedBinaries {
    let names: BTreeSet<String> = ["kubectl", "kumactl", "helm", "docker", "k3d"]
        .iter()
        .map(|s| (*s).to_string())
        .collect();
    DeniedBinaries::new(names)
}

fn make_fixtures(run_dir: &Path, outside: &Path) -> Vec<DriftFixture> {
    vec![
        // Allowed paths
        DriftFixture {
            name: "artifact_in_run_dir",
            path: run_dir.join("artifacts/output.json"),
            expected_allow: true,
            setup: None,
        },
        DriftFixture {
            name: "command_artifact",
            path: run_dir.join("commands/cmd.sh"),
            expected_allow: true,
            setup: None,
        },
        DriftFixture {
            name: "manifest_file",
            path: run_dir.join("manifests/test.yaml"),
            expected_allow: true,
            setup: None,
        },
        DriftFixture {
            name: "state_file",
            path: run_dir.join("state/checkpoint.json"),
            expected_allow: true,
            setup: None,
        },
        // Control files (denied)
        DriftFixture {
            name: "control_run_status",
            path: run_dir.join("run-status.json"),
            expected_allow: false,
            setup: None,
        },
        DriftFixture {
            name: "control_run_report",
            path: run_dir.join("run-report.md"),
            expected_allow: false,
            setup: None,
        },
        DriftFixture {
            name: "control_command_log",
            path: run_dir.join("commands/command-log.md"),
            expected_allow: false,
            setup: None,
        },
        // Traversal escapes
        DriftFixture {
            name: "traversal_escape_etc",
            path: run_dir.join("artifacts/../../../etc/passwd"),
            expected_allow: false,
            setup: None,
        },
        DriftFixture {
            name: "traversal_escape_parent",
            path: run_dir.join("artifacts/../../outside.txt"),
            expected_allow: false,
            setup: None,
        },
        // Outside surface
        DriftFixture {
            name: "outside_absolute",
            path: PathBuf::from("/tmp/evil.txt"),
            expected_allow: false,
            setup: None,
        },
        DriftFixture {
            name: "outside_sibling",
            path: outside.join("sibling.txt"),
            expected_allow: false,
            setup: None,
        },
        // Denied binary in allowed dir
        DriftFixture {
            name: "denied_binary_kubectl",
            path: run_dir.join("artifacts/kubectl"),
            expected_allow: false,
            setup: None,
        },
        DriftFixture {
            name: "denied_binary_kumactl",
            path: run_dir.join("commands/kumactl"),
            expected_allow: false,
            setup: None,
        },
        // Non-canonical paths that resolve inside (should allow)
        DriftFixture {
            name: "noncanonical_dot_inside",
            path: run_dir.join("artifacts/./output.json"),
            expected_allow: true,
            setup: None,
        },
        DriftFixture {
            name: "noncanonical_dotdot_inside",
            path: run_dir.join("artifacts/../artifacts/output.json"),
            expected_allow: true,
            setup: None,
        },
        // File at run_dir root (not in allowed subdir)
        DriftFixture {
            name: "root_file_not_allowed",
            path: run_dir.join("random.txt"),
            expected_allow: false,
            setup: None,
        },
    ]
}

#[cfg(unix)]
fn make_symlink_fixtures(run_dir: &Path, outside: &Path) -> Vec<DriftFixture> {
    vec![DriftFixture {
        name: "symlink_escape",
        path: run_dir.join("artifacts/link"),
        expected_allow: false,
        setup: Some(Box::new({
            let outside = outside.to_path_buf();
            move |run_dir: &Path, _outside: &Path| {
                let target = outside.join("secret.txt");
                fs::write(&target, "secret").expect("write target");
                let link_path = run_dir.join("artifacts/link");
                let _ = fs::remove_file(&link_path);
                symlink(&target, &link_path).expect("create symlink");
            }
        })),
    }]
}

#[cfg(not(unix))]
fn make_symlink_fixtures(_run_dir: &Path, _outside: &Path) -> Vec<DriftFixture> {
    vec![]
}

/// Test the policy function directly.
fn test_policy(
    path: &Path,
    run_dir: &Path,
    denied: &DeniedBinaries,
    expected_allow: bool,
    fixture_name: &str,
) {
    let ctx = WriteSurfaceContext::new(run_dir);
    let result = evaluate_write(path, &ctx, denied);
    let is_allow = result.is_allow();
    assert_eq!(
        is_allow, expected_allow,
        "policy drift: fixture '{fixture_name}' expected allow={expected_allow}, got {:?}",
        result
    );
}

/// Test the hook handler and verify it agrees with the policy.
fn test_hook(path: &Path, run_dir: &Path, expected_allow: bool, fixture_name: &str) {
    let payload = make_write_payload(&path.to_string_lossy());
    let ctx = make_hook_context_with_run("suite:run", payload, run_dir);
    let result = guard_write::execute(&ctx).expect("hook execute");
    let is_allow = result.decision == Decision::Allow;
    assert_eq!(
        is_allow, expected_allow,
        "hook drift: fixture '{fixture_name}' expected allow={expected_allow}, got {:?}: {}",
        result.decision, result.message
    );
}

/// Run both policy and hook against the same fixture, assert agreement.
fn assert_no_drift(
    fixture: &DriftFixture,
    run_dir: &Path,
    outside: &Path,
    denied: &DeniedBinaries,
) {
    // Run any setup
    if let Some(setup) = &fixture.setup {
        setup(run_dir, outside);
    }

    // Test policy function
    test_policy(
        &fixture.path,
        run_dir,
        denied,
        fixture.expected_allow,
        fixture.name,
    );

    // Test hook handler
    test_hook(&fixture.path, run_dir, fixture.expected_allow, fixture.name);
}

#[test]
fn policy_and_hook_produce_identical_decisions() {
    let tmp = tempfile::tempdir().expect("create temp dir");
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let outside = tmp.path().join("outside");
    fs::create_dir_all(&outside).expect("create outside dir");

    let denied = denied_binaries();
    let fixtures = make_fixtures(&run_dir, &outside);

    for fixture in &fixtures {
        assert_no_drift(fixture, &run_dir, &outside, &denied);
    }
}

#[cfg(unix)]
#[test]
fn policy_and_hook_agree_on_symlink_escape() {
    let tmp = tempfile::tempdir().expect("create temp dir");
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let outside = tmp.path().join("outside");
    fs::create_dir_all(&outside).expect("create outside dir");

    let denied = denied_binaries();
    let fixtures = make_symlink_fixtures(&run_dir, &outside);

    for fixture in &fixtures {
        assert_no_drift(fixture, &run_dir, &outside, &denied);
    }
}

#[test]
fn policy_denies_traversal_variations() {
    let tmp = tempfile::tempdir().expect("create temp dir");
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let denied = denied_binaries();
    let ctx = WriteSurfaceContext::new(&run_dir);

    let traversal_paths = [
        run_dir.join("artifacts/../../etc/passwd"),
        run_dir.join("commands/../../../home/user/.ssh/id_rsa"),
        run_dir.join("manifests/sub/../../../../../../tmp/evil"),
        run_dir.join("state/deep/nested/../../../../../../../root"),
    ];

    for path in &traversal_paths {
        let result = evaluate_write(path, &ctx, &denied);
        assert!(
            matches!(
                result,
                WriteDecision::DenyTraversal | WriteDecision::DenyOutsideSurface
            ),
            "traversal path should be denied: {} -> {:?}",
            path.display(),
            result
        );
    }
}

#[test]
fn policy_allows_safe_noncanonical_paths() {
    let tmp = tempfile::tempdir().expect("create temp dir");
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let denied = denied_binaries();
    let ctx = WriteSurfaceContext::new(&run_dir);

    let safe_paths = [
        run_dir.join("artifacts/./file.json"),
        run_dir.join("artifacts/sub/../file.json"),
        run_dir.join("commands/./././script.sh"),
        run_dir.join("manifests/group/../group/test.yaml"),
    ];

    for path in &safe_paths {
        let result = evaluate_write(path, &ctx, &denied);
        assert!(
            result.is_allow(),
            "safe noncanonical path should be allowed: {} -> {:?}",
            path.display(),
            result
        );
    }
}

#[test]
fn policy_denies_all_known_denied_binaries() {
    let tmp = tempfile::tempdir().expect("create temp dir");
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let denied = denied_binaries();
    let ctx = WriteSurfaceContext::new(&run_dir);

    for binary in ["kubectl", "kumactl", "helm", "docker", "k3d"] {
        let path = run_dir.join("artifacts").join(binary);
        let result = evaluate_write(&path, &ctx, &denied);
        assert!(
            matches!(result, WriteDecision::DenyBinary { .. }),
            "denied binary '{}' should be rejected: {:?}",
            binary,
            result
        );
    }
}

#[test]
fn policy_control_file_hints_are_useful() {
    let tmp = tempfile::tempdir().expect("create temp dir");
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let denied = denied_binaries();
    let ctx = WriteSurfaceContext::new(&run_dir);

    let control_files = [
        ("run-status.json", "harness run"),
        ("run-report.md", "harness run"),
        ("commands/command-log.md", "harness run record"),
    ];

    for (file, expected_hint_fragment) in control_files {
        let path = run_dir.join(file);
        let result = evaluate_write(&path, &ctx, &denied);
        if let WriteDecision::DenyControlFile { hint } = result {
            assert!(
                hint.contains(expected_hint_fragment),
                "control file '{}' hint should mention '{}': got '{}'",
                file,
                expected_hint_fragment,
                hint
            );
        } else {
            panic!(
                "control file '{}' should be denied as control file: {:?}",
                file, result
            );
        }
    }
}
