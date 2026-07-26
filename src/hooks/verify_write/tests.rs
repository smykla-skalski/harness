use super::*;
use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::Decision;
use crate::hooks::protocol::payloads::HookEnvelopePayload;
use crate::run::context::RunContext;
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

fn suite_write_context(run_dir: &Path, paths: &[&Path]) -> HookContext {
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
    let mut context = HookContext::from_test_envelope("suite:run", payload);
    context.run_dir = Some(run_dir.to_path_buf());
    context.run = Some(RunContext::from_run_dir(run_dir).unwrap());
    context
}

#[test]
fn verify_suite_runner_requires_amendment_for_suite_source_writes() {
    let tempdir = tempfile::tempdir().unwrap();
    let (run_dir, suite_dir) = build_test_run_dir(tempdir.path(), "r01");
    let suite_manifest = suite_dir.join("suite.md");

    let context = suite_write_context(&run_dir, &[suite_manifest.as_path()]);

    let outcome = execute(&context).unwrap();
    assert_eq!(outcome.to_hook_result().decision, Decision::Warn);
}

#[test]
fn verify_suite_runner_allows_amendments_write() {
    let tempdir = tempfile::tempdir().unwrap();
    let (run_dir, suite_dir) = build_test_run_dir(tempdir.path(), "r01");
    let amendments = suite_dir.join("amendments.md");
    fs::write(&amendments, "changes\n").unwrap();

    let context = suite_write_context(&run_dir, &[amendments.as_path()]);

    let outcome = execute(&context).unwrap();
    assert_eq!(outcome.to_hook_result().decision, Decision::Allow);
}
