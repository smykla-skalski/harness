use std::path::Path;

use harness_bridge::errors::{CliError, CliErrorKind};
use harness_bridge::feature_flags::RuntimeHookFlags;
use harness_bridge::hooks::adapters::HookAgent;

#[test]
fn bridge_uses_canonical_runner_state_name() {
    assert_eq!(
        harness_bridge::kernel::skills::dirs::RUN_STATE_FILE,
        "suite-run-state.json"
    );
    assert_eq!(
        harness_bridge::kernel::skills::dirs::RUN_STATE_FILE,
        harness_hook::kernel::skills::dirs::RUN_STATE_FILE
    );
}

#[test]
fn bridge_uses_the_current_daemon_launch_agent_name() {
    assert_eq!(
        harness_bridge::daemon::state::launch_agent_path()
            .file_name()
            .and_then(|name| name.to_str()),
        Some("io.harness.daemon.plist")
    );
}

#[test]
fn bridge_preserves_common_error_codes_and_exit_statuses() {
    let sandbox: CliError = CliErrorKind::sandbox_feature_disabled("codex.stdio").into();
    assert_eq!(sandbox.code(), "SANDBOX001");
    assert_eq!(sandbox.exit_code(), 1);

    let codex: CliError = CliErrorKind::codex_server_unavailable("ws://localhost").into();
    assert_eq!(codex.code(), "CODEX001");
    assert_eq!(codex.exit_code(), 1);
}

#[test]
fn bridge_uses_canonical_project_context_semantics() {
    let temporary = tempfile::tempdir().expect("temporary directory");
    let project = temporary.path().join("project");
    fs_err::create_dir_all(project.join("nested")).expect("create project");

    let bridge_context = harness_bridge::workspace::project_context_dir(&project);
    assert_eq!(
        bridge_context,
        harness_hook::workspace::project_context_dir(&project)
    );
    assert_eq!(
        harness_bridge::workspace::project_context_dir(&bridge_context.join("agents")),
        bridge_context,
        "an existing project context must remain idempotent"
    );
}

#[test]
fn bridge_setup_writes_the_real_agent_bootstrap() {
    let temporary = tempfile::tempdir().expect("temporary directory");
    let written = harness_bridge::setup::wrapper::write_agent_bootstrap(
        temporary.path(),
        HookAgent::Claude,
        &[],
        RuntimeHookFlags::all_enabled(),
    )
    .expect("write Claude bootstrap");
    let settings = temporary.path().join(".claude/settings.json");

    assert_eq!(written, vec![settings.clone()]);
    let contents = fs_err::read_to_string(settings).expect("read Claude settings");
    assert!(contents.contains("harness-hook session-start"));
    assert!(contents.contains("harness-hook guard-stop"));
}

#[test]
fn bridge_setup_installs_an_executable_wrapper() {
    let temporary = tempfile::tempdir().expect("temporary directory");
    let bin = temporary.path().join(".local/bin");
    fs_err::create_dir_all(&bin).expect("create bin directory");

    let result = harness_bridge::setup::wrapper::main_with_home(
        Path::new("."),
        bin.to_str().expect("UTF-8 path"),
        temporary.path(),
    )
    .expect("install wrapper");
    assert_eq!(result, 0);

    let wrapper = bin.join("harness");
    let contents = fs_err::read_to_string(&wrapper).expect("read installed wrapper");
    assert!(contents.contains("unable to resolve a current harness binary"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        assert_ne!(
            fs_err::metadata(wrapper)
                .expect("wrapper metadata")
                .permissions()
                .mode()
                & 0o111,
            0
        );
    }
}

#[test]
fn bridge_io_rejects_canonical_unsafe_names() {
    let error = harness_bridge::infra::io::validate_safe_segment("safe..looking")
        .expect_err("embedded dot-dot is unsafe");
    assert_eq!(error.code(), "KSRCLI059");
}

#[test]
fn bridge_io_uses_canonical_private_file_permissions() {
    let temporary = tempfile::tempdir().expect("temporary directory");
    let state = temporary.path().join("state.json");
    harness_bridge::infra::io::write_text(&state, "{}\n").expect("write state");

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        assert_eq!(
            fs_err::metadata(state)
                .expect("state metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}

#[test]
fn bridge_runs_startup_migrations_before_command_execution() {
    let main_source = include_str!("../src/main.rs");
    let migration = main_source
        .find("harness_bridge::app::run_startup_migrations();")
        .expect("bridge main invokes startup migrations");
    let execution = main_source
        .find("cli.command.execute(&AppContext::production())")
        .expect("bridge main executes the parsed command");

    assert!(
        migration < execution,
        "migration must run before command execution"
    );
}
