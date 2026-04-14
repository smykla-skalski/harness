use crate::daemon::agent_tui::{
    AgentTuiInput, AgentTuiKey, AgentTuiLaunchProfile, AgentTuiSize, TerminalScreenParser,
};

use super::support::{
    WAIT_TIMEOUT, spawn_runtime, spawn_shell, wait_until, write_executable_script,
};

#[test]
fn launch_profiles_cover_all_supported_runtimes() {
    let cases = [
        ("codex", "codex"),
        ("claude", "claude"),
        ("gemini", "gemini"),
        ("opencode", "opencode"),
        ("copilot", "copilot"),
        ("vibe", "vibe"),
    ];

    for (runtime, program) in cases {
        let profile = AgentTuiLaunchProfile::for_runtime(runtime).expect("profile");
        assert_eq!(profile.runtime, runtime);
        assert_eq!(profile.argv, vec![program.to_string()]);
    }
}

#[test]
fn launch_profile_rejects_unknown_runtime() {
    let error = AgentTuiLaunchProfile::for_runtime("unknown").expect_err("runtime should fail");

    assert!(
        error
            .to_string()
            .contains("unsupported agent TUI runtime 'unknown'")
    );
}

#[test]
fn launch_profile_override_rejects_empty_argv() {
    let error =
        AgentTuiLaunchProfile::from_argv("codex", Vec::new()).expect_err("argv should fail");

    assert!(error.to_string().contains("agent TUI argv cannot be empty"));
}

#[test]
fn launch_profile_override_rejects_empty_program() {
    let error = AgentTuiLaunchProfile::from_argv("codex", vec![" ".to_string()])
        .expect_err("program should fail");

    assert!(
        error
            .to_string()
            .contains("agent TUI argv[0] cannot be empty")
    );
}

#[test]
fn structured_input_maps_to_terminal_bytes() {
    assert_eq!(
        AgentTuiInput::Text {
            text: "hello".into()
        }
        .to_bytes()
        .expect("text bytes"),
        b"hello"
    );
    assert_eq!(
        AgentTuiInput::Key {
            key: AgentTuiKey::Enter
        }
        .to_bytes()
        .expect("enter bytes"),
        b"\r"
    );
    assert_eq!(
        AgentTuiInput::Key {
            key: AgentTuiKey::ArrowUp
        }
        .to_bytes()
        .expect("arrow bytes"),
        b"\x1b[A"
    );
    assert_eq!(
        AgentTuiInput::Control { key: 'c' }
            .to_bytes()
            .expect("control bytes"),
        b"\x03"
    );
}

#[test]
fn paste_uses_bracketed_paste_sequences() {
    let bytes = AgentTuiInput::Paste {
        text: "multi\nline".into(),
    }
    .to_bytes()
    .expect("paste bytes");

    assert_eq!(bytes, b"\x1b[200~multi\nline\x1b[201~");
}

#[test]
fn raw_bytes_decode_from_base64() {
    let bytes = AgentTuiInput::RawBytesBase64 {
        data: "AAEC".into(),
    }
    .to_bytes()
    .expect("raw bytes");

    assert_eq!(bytes, vec![0, 1, 2]);
}

#[test]
fn size_rejects_zero_dimensions() {
    let error = AgentTuiSize { rows: 0, cols: 120 }
        .validate()
        .expect_err("size should fail");

    assert!(
        error
            .to_string()
            .contains("agent TUI rows and cols must be greater than zero")
    );
}

#[test]
fn terminal_parser_preserves_visible_text_and_resize() {
    let mut parser = TerminalScreenParser::new(AgentTuiSize { rows: 4, cols: 20 });
    parser.process(b"hello\x1b[2;1Hworld");
    let snapshot = parser.snapshot();
    assert_eq!(snapshot.rows, 4);
    assert_eq!(snapshot.cols, 20);
    assert!(snapshot.text.contains("hello"));
    assert!(snapshot.text.contains("world"));

    parser.resize(AgentTuiSize { rows: 10, cols: 40 });
    let resized = parser.snapshot();
    assert_eq!(resized.rows, 10);
    assert_eq!(resized.cols, 40);
}

#[test]
fn terminal_parser_trims_leading_blank_rows() {
    let mut parser = TerminalScreenParser::new(AgentTuiSize { rows: 5, cols: 40 });
    parser.process(b"\x1b[3;1Hhello");

    let snapshot = parser.snapshot();
    assert!(
        snapshot.text.starts_with("hello"),
        "should start with content, got: {:?}",
        &snapshot.text[..snapshot.text.len().min(40)]
    );
}

#[test]
fn terminal_parser_trims_space_filled_rows() {
    let mut parser = TerminalScreenParser::new(AgentTuiSize { rows: 32, cols: 80 });
    parser.process(b"\x1b[?1049h");
    for row in 1..=19 {
        let cmd = format!("\x1b[{row};1H{}", " ".repeat(80));
        parser.process(cmd.as_bytes());
    }
    parser.process(b"\x1b[20;1HMistral Vibe v2.7.4");

    let snapshot = parser.snapshot();
    assert!(
        snapshot.text.starts_with("Mistral Vibe"),
        "should start with content, got: {:?}",
        &snapshot.text[..snapshot.text.len().min(40)]
    );
}

#[test]
fn terminal_parser_preserves_row_zero_content() {
    let mut parser = TerminalScreenParser::new(AgentTuiSize { rows: 5, cols: 40 });
    parser.process(b"top-content");

    let snapshot = parser.snapshot();
    assert!(snapshot.text.starts_with("top-content"));
}

#[test]
fn portable_pty_backend_round_trips_line_input() {
    let process = spawn_shell("cat");
    process
        .send_input(&AgentTuiInput::Text {
            text: "hello from pty".into(),
        })
        .expect("send text");
    process
        .send_input(&AgentTuiInput::Key {
            key: AgentTuiKey::Enter,
        })
        .expect("send enter");

    wait_until(WAIT_TIMEOUT, || {
        String::from_utf8_lossy(&process.transcript().expect("transcript"))
            .contains("hello from pty")
    });
}

#[test]
fn portable_pty_backend_preserves_raw_ansi_and_parses_screen_text() {
    let process = spawn_shell("printf '\\033[31mred\\033[0m\\n'");
    let status = process
        .wait_timeout(WAIT_TIMEOUT)
        .expect("wait")
        .expect("status");
    assert!(status.success());

    let transcript = process.transcript().expect("transcript");
    assert!(
        transcript
            .windows(b"\x1b[31m".len())
            .any(|chunk| chunk == b"\x1b[31m")
    );
    assert!(process.screen().expect("screen").text.contains("red"));
}

#[test]
fn portable_pty_backend_sends_control_c() {
    let process = spawn_shell("sleep 10");
    process
        .send_input(&AgentTuiInput::Control { key: 'c' })
        .expect("send ctrl-c");

    let status = process
        .wait_timeout(WAIT_TIMEOUT)
        .expect("wait for interrupt");
    assert!(status.is_some(), "process should exit after ctrl-c");
}

#[test]
fn portable_pty_backend_resizes_screen_model() {
    let process = spawn_shell("cat");
    process
        .resize(AgentTuiSize { rows: 9, cols: 33 })
        .expect("resize");

    let screen = process.screen().expect("screen");
    assert_eq!(screen.rows, 9);
    assert_eq!(screen.cols, 33);
}

#[test]
fn portable_pty_backend_resolves_vibe_from_local_bin_when_missing_from_path() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let vibe = home.join(".local").join("bin").join("vibe");
    write_executable_script(&vibe, "#!/bin/sh\nprintf 'vibe-local-bin\\n'\n");

    temp_env::with_vars(
        [
            ("HOME", Some(home.to_str().expect("utf8 home"))),
            ("PATH", Some("/usr/bin:/bin")),
        ],
        || {
            let process = spawn_runtime("vibe");
            let status = process
                .wait_timeout(WAIT_TIMEOUT)
                .expect("wait")
                .expect("status");
            assert!(status.success());
            assert!(
                process
                    .screen()
                    .expect("screen")
                    .text
                    .contains("vibe-local-bin")
            );
        },
    );
}

#[test]
fn portable_pty_backend_resolves_vibe_from_uv_tool_dir_without_local_bin_symlink() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let vibe = home
        .join(".local")
        .join("share")
        .join("uv")
        .join("tools")
        .join("mistral-vibe")
        .join("bin")
        .join("vibe");
    write_executable_script(&vibe, "#!/bin/sh\nprintf 'vibe-uv-tool\\n'\n");

    temp_env::with_vars(
        [
            ("HOME", Some(home.to_str().expect("utf8 home"))),
            ("PATH", Some("/usr/bin:/bin")),
        ],
        || {
            let process = spawn_runtime("vibe");
            let status = process
                .wait_timeout(WAIT_TIMEOUT)
                .expect("wait")
                .expect("status");
            assert!(status.success());
            assert!(
                process
                    .screen()
                    .expect("screen")
                    .text
                    .contains("vibe-uv-tool")
            );
        },
    );
}
