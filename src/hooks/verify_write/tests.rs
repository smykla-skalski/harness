use super::*;
use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::Decision;
use crate::hooks::protocol::payloads::HookEnvelopePayload;
use crate::run::test_support::build_test_run_dir;

#[test]
fn verify_suite_create_empty_amendments_denies() {
    let tmp = tempfile::NamedTempFile::new().unwrap();
    let path = tmp.path().parent().unwrap().join("amendments.md");
    fs::write(&path, "   \n").unwrap();
    let result = verify_suite_create(&[path.as_path()]);
    assert_eq!(result.decision, Decision::Deny);
    let _ = fs::remove_file(&path);
}

#[test]
fn verify_suite_create_nonempty_amendments_allows() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("amendments.md");
    fs::write(&path, "real content here\n").unwrap();
    let result = verify_suite_create(&[path.as_path()]);
    assert_eq!(result.decision, Decision::Allow);
}

/// `observe` is the skill that still confirms a session and therefore still
/// reaches the non-create branch.
fn run_write_context(run_dir: &Path, paths: &[&Path]) -> HookContext {
    let payload = HookEnvelopePayload {
        tool_name: "Write".to_string(),
        tool_input: serde_json::json!({
            "file_paths": paths
                .iter()
                .map(|path| path.to_string_lossy())
                .collect::<Vec<_>>(),
        }),
        tool_response: serde_json::Value::Null,
        last_assistant_message: None,
        transcript_path: None,
        stop_hook_active: false,
        raw_keys: vec![],
    };
    let mut context = HookContext::from_test_envelope("observe", payload);
    context.run_dir = Some(run_dir.to_path_buf());
    context
}

#[test]
fn denies_writes_to_command_owned_run_files() {
    let tempdir = tempfile::tempdir().unwrap();
    let (run_dir, _) = build_test_run_dir(tempdir.path(), "r01");
    let command_log = run_dir.join("commands").join("command-log.md");

    let context = run_write_context(&run_dir, &[command_log.as_path()]);
    assert!(context.skill_active, "case must reach the guard body");

    let outcome = execute(&context).unwrap();
    assert_eq!(outcome.to_hook_result().decision, Decision::Deny);
}

#[test]
fn allows_writes_to_ordinary_run_artifacts() {
    let tempdir = tempfile::tempdir().unwrap();
    let (run_dir, _) = build_test_run_dir(tempdir.path(), "r01");
    let artifact = run_dir.join("artifacts").join("output.json");

    let context = run_write_context(&run_dir, &[artifact.as_path()]);

    let outcome = execute(&context).unwrap();
    assert_eq!(outcome.to_hook_result().decision, Decision::Allow);
}
