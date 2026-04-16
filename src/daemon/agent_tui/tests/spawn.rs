use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

use crate::agents::runtime::InitialPromptDelivery;
use crate::daemon::agent_tui::{
    AgentTuiBackend, AgentTuiInput, AgentTuiLaunchProfile, AgentTuiSize, AgentTuiSpawnSpec,
    PortablePtyAgentTuiBackend,
};
use crate::session::types::SessionRole;

use super::super::spawn::ensure_runtime_bootstrap;
use super::super::{
    build_auto_join_prompt, resolved_command_argv, send_initial_prompt, signal_readiness_ready,
    skill_directory_flags, spawn_agent_tui_process,
};
use super::support::{WAIT_TIMEOUT, spawn_shell_with_readiness};

#[test]
fn ensure_runtime_bootstrap_writes_runtime_assets_for_all_supported_agents() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let project = tmp.path().join("project");
    let home_env = home.to_string_lossy().into_owned();
    fs_err::create_dir_all(&home).expect("home dir");
    fs_err::create_dir_all(home.join(".local")).expect("home local dir");
    fs_err::create_dir_all(&project).expect("project dir");

    temp_env::with_var("HOME", Some(home_env.as_str()), || {
        for (runtime, expected_paths) in [
            (
                "claude",
                vec![
                    ".claude/settings.json",
                    ".claude/plugins/harness/skills/join/SKILL.md",
                ],
            ),
            (
                "codex",
                vec![
                    ".codex/hooks.json",
                    ".codex/config.toml",
                    ".agents/skills/harness-session-join/SKILL.md",
                    "plugins/harness/skills/join/SKILL.md",
                ],
            ),
            (
                "gemini",
                vec![
                    ".gemini/settings.json",
                    ".gemini/commands/harness/session/join.toml",
                ],
            ),
            (
                "copilot",
                vec![
                    ".github/hooks/harness.json",
                    "plugins/harness/skills/join/SKILL.md",
                ],
            ),
            (
                "vibe",
                vec![
                    ".vibe/hooks.json",
                    ".vibe/plugins/harness/skills/join/SKILL.md",
                ],
            ),
            (
                "opencode",
                vec![
                    ".opencode/hooks.json",
                    ".opencode/plugins/harness/skills/join/SKILL.md",
                ],
            ),
        ] {
            ensure_runtime_bootstrap(runtime, &project)
                .unwrap_or_else(|error| panic!("bootstrap {runtime}: {error}"));

            for relative_path in expected_paths {
                assert!(
                    project.join(relative_path).is_file(),
                    "expected {runtime} bootstrap to write {relative_path}"
                );
            }
        }
    });

    assert!(
        home.join(".local").join("bin").join("harness").is_file(),
        "bootstrap should install the harness wrapper into the user bin dir"
    );
}

#[test]
fn spawn_agent_tui_process_bootstraps_runtime_assets_before_launch() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let project = tmp.path().join("project");
    let home_env = home.to_string_lossy().into_owned();
    fs_err::create_dir_all(&home).expect("home dir");
    fs_err::create_dir_all(home.join(".local")).expect("home local dir");
    fs_err::create_dir_all(&project).expect("project dir");

    temp_env::with_var("HOME", Some(home_env.as_str()), || {
        let profile =
            AgentTuiLaunchProfile::from_argv("codex", vec!["sh".into(), "-c".into(), "cat".into()])
                .expect("profile");
        let process = spawn_agent_tui_process(
            "sess-bootstrap-spawn",
            "agent-tui-bootstrap",
            profile,
            &project,
            AgentTuiSize { rows: 5, cols: 40 },
            None,
        )
        .expect("spawn process");

        assert!(
            project.join(".codex").join("hooks.json").is_file(),
            "spawn should bootstrap Codex hooks before launch"
        );
        assert!(
            project
                .join(".agents")
                .join("skills")
                .join("harness-session-join")
                .join("SKILL.md")
                .is_file(),
            "spawn should bootstrap the direct join skill before launch"
        );

        process.kill().expect("kill process");
        let _ = process
            .wait_timeout(Duration::from_millis(200))
            .expect("wait after kill");
    });
}

#[test]
fn skill_directory_flags_claude_returns_plugin_dir() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let project = tmp.path().join("project");
    let plugin = project.join(".claude").join("plugins").join("harness");
    fs_err::create_dir_all(&plugin).expect("create plugin dir");

    let flags = skill_directory_flags("claude", &project);
    assert_eq!(flags.len(), 2);
    assert_eq!(flags[0], "--plugin-dir");
    assert_eq!(PathBuf::from(&flags[1]), plugin);
}

#[test]
fn skill_directory_flags_codex_returns_empty() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let flags = skill_directory_flags("codex", tmp.path());
    assert!(flags.is_empty());
}

#[test]
fn skill_directory_flags_copilot_returns_plugin_dir() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let project = tmp.path().join("project");
    let plugin = project.join("plugins").join("harness");
    fs_err::create_dir_all(&plugin).expect("create plugin dir");

    let flags = skill_directory_flags("copilot", &project);
    assert_eq!(flags.len(), 2);
    assert_eq!(flags[0], "--plugin-dir");
    assert_eq!(PathBuf::from(&flags[1]), plugin);
}

#[test]
fn skill_directory_flags_missing_dir_returns_empty() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let project = tmp.path().join("nonexistent");
    let flags = skill_directory_flags("claude", &project);
    assert!(flags.is_empty());
}

#[test]
fn build_auto_join_prompt_includes_markers() {
    let prompt = build_auto_join_prompt(
        "codex",
        "sess-123",
        SessionRole::Worker,
        None,
        &[],
        "agent-tui-abc",
        None,
        None,
    );
    assert!(prompt.contains("sess-123"), "should contain session id");
    assert!(
        prompt.contains("agent-tui"),
        "should contain agent-tui capability"
    );
    assert!(
        prompt.contains("agent-tui:agent-tui-abc"),
        "should contain marker capability"
    );
    assert!(prompt.contains("worker"), "should contain role");
    assert!(prompt.contains("codex"), "should contain runtime");
}

#[test]
fn build_auto_join_prompt_preserves_user_capabilities() {
    let prompt = build_auto_join_prompt(
        "claude",
        "sess-456",
        SessionRole::Observer,
        None,
        &["custom-cap".to_string(), "another".to_string()],
        "agent-tui-def",
        Some("my worker"),
        None,
    );
    assert!(prompt.contains("custom-cap"), "should preserve user cap");
    assert!(prompt.contains("another"), "should preserve user cap");
    assert!(
        prompt.contains("agent-tui:agent-tui-def"),
        "should contain marker"
    );
    assert!(prompt.contains("observer"), "should contain role");
    assert!(prompt.contains("my worker"), "should contain name");
}

#[test]
fn readiness_flag_set_when_reader_encounters_pattern() {
    let process =
        spawn_shell_with_readiness("printf 'loading...\\n\u{256d} ready\\n'", Some("\u{256d}"));
    assert!(
        process.wait_ready(WAIT_TIMEOUT),
        "readiness flag should be set when pattern appears in output"
    );
}

#[test]
fn readiness_times_out_and_join_still_sent() {
    let process = spawn_shell_with_readiness("sleep 30", Some("\u{256d}"));
    let ready = process.wait_ready(Duration::from_millis(200));
    assert!(
        !ready,
        "wait_ready should return false when pattern never appears"
    );
    assert!(
        process
            .send_input(&AgentTuiInput::Control { key: 'c' })
            .is_ok(),
        "should still be able to send input after readiness timeout"
    );
}

#[test]
fn join_message_not_sent_before_readiness() {
    let process = spawn_shell_with_readiness(
        "sleep 0.3 && printf '\u{256d} ready\\n' && cat",
        Some("\u{256d}"),
    );

    let raw = process.transcript().expect("transcript");
    let transcript_before = String::from_utf8_lossy(&raw);
    assert!(
        !transcript_before.contains("test-join-msg"),
        "no input should have been sent yet"
    );

    assert!(process.wait_ready(WAIT_TIMEOUT), "should become ready");

    send_initial_prompt(&process, "test-join-msg").expect("send after ready");
    super::support::wait_until(WAIT_TIMEOUT, || {
        String::from_utf8_lossy(&process.transcript().expect("transcript"))
            .contains("test-join-msg")
    });
}

#[test]
fn callback_readiness_unblocks_wait_ready() {
    let process = spawn_shell_with_readiness("cat", None);

    let immediate = process.wait_ready(Duration::from_millis(50));
    assert!(
        !immediate,
        "wait_ready should not return true without callback"
    );

    let readiness = process.readiness_signal();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(100));
        signal_readiness_ready(&readiness);
    });

    assert!(
        process.wait_ready(WAIT_TIMEOUT),
        "wait_ready should return true after callback signal"
    );
}

#[test]
fn callback_readiness_times_out_without_signal() {
    let process = spawn_shell_with_readiness("sleep 30", None);
    let ready = process.wait_ready(Duration::from_millis(200));
    assert!(
        !ready,
        "wait_ready should return false when no callback arrives"
    );
}

#[test]
fn build_auto_join_prompt_includes_persona_flag() {
    let prompt = build_auto_join_prompt(
        "codex",
        "sess-789",
        SessionRole::Worker,
        None,
        &[],
        "agent-tui-xyz",
        None,
        Some("code-reviewer"),
    );
    assert!(
        prompt.contains("--persona \"code-reviewer\""),
        "should contain persona flag: {prompt}"
    );
}

#[test]
fn build_auto_join_prompt_omits_persona_when_none() {
    let prompt = build_auto_join_prompt(
        "codex",
        "sess-789",
        SessionRole::Worker,
        None,
        &[],
        "agent-tui-xyz",
        None,
        None,
    );
    assert!(
        !prompt.contains("--persona"),
        "should not contain persona flag when None: {prompt}"
    );
}

#[test]
fn cli_positional_appends_prompt_to_argv() {
    let profile = AgentTuiLaunchProfile::from_argv("codex", vec!["codex".into()]).expect("profile");
    let mut spec = AgentTuiSpawnSpec::new(
        profile,
        PathBuf::from("/tmp/project"),
        BTreeMap::new(),
        AgentTuiSize { rows: 5, cols: 40 },
    )
    .expect("spec");
    spec.prompt_delivery = InitialPromptDelivery::CliPositional;
    spec.cli_prompt = Some("/harness:session:join test-session".into());

    let argv = resolved_command_argv(&spec);
    let last = argv.last().expect("last arg");
    assert_eq!(
        last.to_str().expect("utf8"),
        "/harness:session:join test-session"
    );
}

#[test]
fn cli_flag_appends_flag_and_prompt() {
    let profile =
        AgentTuiLaunchProfile::from_argv("gemini", vec!["gemini".into()]).expect("profile");
    let mut spec = AgentTuiSpawnSpec::new(
        profile,
        PathBuf::from("/tmp/project"),
        BTreeMap::new(),
        AgentTuiSize { rows: 5, cols: 40 },
    )
    .expect("spec");
    spec.prompt_delivery = InitialPromptDelivery::CliFlag("--prompt-interactive");
    spec.cli_prompt = Some("/harness:session:join test-session".into());

    let argv = resolved_command_argv(&spec);
    let argv_strings: Vec<_> = argv
        .iter()
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect();
    assert!(
        argv_strings.contains(&"--prompt-interactive".to_string()),
        "should contain flag: {argv_strings:?}"
    );
    assert!(
        argv_strings.contains(&"/harness:session:join test-session".to_string()),
        "should contain prompt: {argv_strings:?}"
    );
}

#[test]
fn pty_send_does_not_modify_argv() {
    let profile =
        AgentTuiLaunchProfile::from_argv("copilot", vec!["copilot".into()]).expect("profile");
    let mut spec = AgentTuiSpawnSpec::new(
        profile,
        PathBuf::from("/tmp/project"),
        BTreeMap::new(),
        AgentTuiSize { rows: 5, cols: 40 },
    )
    .expect("spec");
    spec.prompt_delivery = InitialPromptDelivery::PtySend;
    spec.cli_prompt = None;

    let argv = resolved_command_argv(&spec);
    let argv_strings: Vec<_> = argv
        .iter()
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect();
    assert!(
        !argv_strings
            .iter()
            .any(|arg| arg.contains("harness:session:join")),
        "PtySend should not inject prompt into argv: {argv_strings:?}"
    );
}

#[test]
fn screen_text_fallback_signals_on_visible_content() {
    let profile = AgentTuiLaunchProfile::from_argv(
        "codex",
        vec![
            "sh".to_string(),
            "-c".to_string(),
            "printf '\\033[?1049h\\033[?25l'; sleep 0.3; printf 'Vibe ready>\\n'; cat".to_string(),
        ],
    )
    .expect("profile");
    let mut spec = AgentTuiSpawnSpec::new(
        profile,
        PathBuf::from("."),
        BTreeMap::new(),
        AgentTuiSize { rows: 30, cols: 80 },
    )
    .expect("spec");
    spec.screen_text_fallback = true;

    let process = PortablePtyAgentTuiBackend.spawn(spec).expect("spawn");

    let early = process.wait_ready(Duration::from_millis(100));
    assert!(
        !early,
        "screen-text fallback should not fire on escape codes alone"
    );

    assert!(
        process.wait_ready(WAIT_TIMEOUT),
        "screen-text fallback should fire when visible content appears"
    );
}
