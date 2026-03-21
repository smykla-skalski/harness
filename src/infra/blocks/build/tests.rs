use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use super::*;
use crate::infra::blocks::{FakeProcessExecutor, FakeProcessMethod, FakeResponse};
use crate::infra::exec::CommandResult;

fn success_result(args: &[&str]) -> CommandResult {
    CommandResult {
        args: args.iter().map(|arg| (*arg).to_string()).collect(),
        returncode: 0,
        stdout: String::new(),
        stderr: String::new(),
    }
}

#[test]
fn build_target_make_uses_make_program() {
    let target = BuildTarget::make("check");

    assert_eq!(target.program, "make");
    assert_eq!(target.args, vec!["check"]);
    assert!(target.cwd.is_none());
    assert!(target.env.is_empty());
}

#[test]
fn build_target_mise_uses_mise_run_task() {
    let target = BuildTarget::mise("check");

    assert_eq!(target.program, "mise");
    assert_eq!(target.args, vec!["run", "check"]);
    assert!(target.cwd.is_none());
    assert!(target.env.is_empty());
}

#[test]
fn process_build_system_runs_target_with_process_block() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "make".to_string(),
        expected_args: Some(vec!["make".into(), "check".into()]),
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(&["make", "check"])),
    }]));
    let build = ProcessBuildSystem::new(fake);

    let result = build
        .run_target(&BuildTarget::make("check"))
        .expect("expected build target to succeed");

    assert_eq!(result.returncode, 0);
}

#[test]
fn process_build_system_runs_streaming_target_with_process_block() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "mise".to_string(),
        expected_args: Some(vec!["mise".into(), "run".into(), "test".into()]),
        expected_method: Some(FakeProcessMethod::RunStreaming),
        result: Ok(success_result(&["mise", "run", "test"])),
    }]));
    let build = ProcessBuildSystem::new(fake);

    let result = build
        .run_target_streaming(&BuildTarget::mise("test"))
        .expect("expected streaming build target to succeed");

    assert_eq!(result.returncode, 0);
}

#[test]
fn run_named_target_sets_cwd_on_make_target() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "make".to_string(),
        expected_args: Some(vec!["make".into(), "install".into()]),
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(&["make", "install"])),
    }]));
    let build = ProcessBuildSystem::new(fake);

    let result = build
        .run_named_target("install", Some(Path::new("/tmp")))
        .expect("expected named target to succeed");

    assert_eq!(result.returncode, 0);
}

#[test]
fn build_target_serializes_roundtrip() {
    let mut env = HashMap::new();
    env.insert("PROFILE".to_string(), "dev".to_string());

    let target = BuildTarget {
        program: "mise".to_string(),
        args: vec!["run".to_string(), "check".to_string()],
        cwd: Some("/repo".to_string()),
        env,
    };

    let json = serde_json::to_string(&target).expect("serialize target");
    let back: BuildTarget = serde_json::from_str(&json).expect("deserialize target");

    assert_eq!(back, target);
}

#[test]
fn build_types_are_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}

    assert_send_sync::<BuildTarget>();
    assert_send_sync::<ProcessBuildSystem>();
}

#[test]
fn fake_build_system_records_invocations() {
    let fake = FakeBuildSystem::success();
    let target = BuildTarget::make("check");
    let result = fake.run_target(&target).expect("should succeed");

    assert_eq!(result.returncode, 0);
    let invocations = fake.invocations();
    assert_eq!(invocations.len(), 1);
    assert_eq!(invocations[0].program, "make");
}

#[test]
fn fake_build_system_returns_custom_result() {
    let custom = CommandResult {
        args: vec!["make".into(), "test".into()],
        returncode: 2,
        stdout: "output".into(),
        stderr: "err".into(),
    };
    let fake = FakeBuildSystem::with_result(custom);
    let result = fake
        .run_target(&BuildTarget::make("test"))
        .expect("should return custom result");
    assert_eq!(result.returncode, 2);
    assert_eq!(result.stdout, "output");
}

mod contracts {
    use super::*;

    fn contract_name_is_non_empty(build: &dyn BuildSystem) {
        assert!(!build.name().is_empty(), "block name should not be empty");
    }

    fn contract_denied_binaries_is_stable(build: &dyn BuildSystem) {
        let first = build.denied_binaries();
        let second = build.denied_binaries();
        assert_eq!(first, second, "denied_binaries should be stable");
    }

    fn contract_run_target_does_not_panic(build: &dyn BuildSystem) {
        let _ = build.run_target(&BuildTarget::make("echo-test"));
    }

    fn contract_run_target_streaming_does_not_panic(build: &dyn BuildSystem) {
        let _ = build.run_target_streaming(&BuildTarget::make("echo-test"));
    }

    #[test]
    fn fake_satisfies_name_is_non_empty() {
        contract_name_is_non_empty(&FakeBuildSystem::success());
    }

    #[test]
    fn fake_satisfies_denied_binaries_is_stable() {
        contract_denied_binaries_is_stable(&FakeBuildSystem::success());
    }

    #[test]
    fn fake_satisfies_run_target_does_not_panic() {
        contract_run_target_does_not_panic(&FakeBuildSystem::success());
    }

    #[test]
    fn fake_satisfies_run_target_streaming_does_not_panic() {
        contract_run_target_streaming_does_not_panic(&FakeBuildSystem::success());
    }
}
