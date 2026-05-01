use std::ffi::OsString;
use std::fs;
use std::path::PathBuf;
use std::path::Path;
use std::thread;
use std::time::Duration;

use std::os::unix::fs::PermissionsExt;

use crate::mcp::registry::ElementKind;

use super::accessibility::{get_element_args, list_elements_args};
use super::backend::{
    Backend, INPUT_OVERRIDE_ENV, default_helper_candidate_from_roots, default_helper_candidate_in,
    detect_backend,
    helper_search_roots_from,
};
use super::input::{MouseButton, click_args, move_mouse_args, type_text_args};
use super::screenshot::{ScreenshotOptions, screencapture_args};

fn as_strings(args: &[OsString]) -> Vec<String> {
    args.iter()
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect()
}

fn write_helper_script(path: &Path, body: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create helper parent");
    }
    fs::write(path, body).expect("write helper script");
    let mut permissions = fs::metadata(path).expect("helper metadata").permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).expect("set helper executable");
}

fn valid_helper_script() -> &'static str {
    "#!/bin/sh\nexit 0\n"
}

fn failing_helper_script() -> &'static str {
    "#!/bin/sh\nexit 1\n"
}

#[test]
fn move_mouse_uses_harness_input_subcommand_and_rounded_coords() {
    let backend = Backend::HarnessInput(PathBuf::from("/path/to/helper"));
    let (program, args) = move_mouse_args(&backend, 12.4, -7.9).expect("backend available");
    assert_eq!(program, OsString::from("/path/to/helper"));
    assert_eq!(as_strings(&args), vec!["move", "12", "-8"]);
}

#[test]
fn move_mouse_under_cliclick_formats_mx_y() {
    let (program, args) =
        move_mouse_args(&Backend::Cliclick, 100.0, 200.0).expect("backend available");
    assert_eq!(program, OsString::from("cliclick"));
    assert_eq!(as_strings(&args), vec!["m:100,200"]);
}

#[test]
fn move_mouse_without_backend_is_none() {
    assert!(move_mouse_args(&Backend::None, 0.0, 0.0).is_none());
}

#[test]
fn click_harness_input_double_right_includes_flags() {
    let backend = Backend::HarnessInput(PathBuf::from("/tmp/helper"));
    let (_, args) = click_args(&backend, 1.0, 2.0, MouseButton::Right, true).unwrap();
    assert_eq!(
        as_strings(&args),
        vec!["click", "1", "2", "--button", "right", "--double"],
    );
}

#[test]
fn click_cliclick_double_uses_dc_verb() {
    let (_, args) = click_args(&Backend::Cliclick, 5.0, 6.0, MouseButton::Left, true).unwrap();
    assert_eq!(as_strings(&args), vec!["dc:5,6"]);
}

#[test]
fn click_cliclick_right_uses_rc_verb() {
    let (_, args) = click_args(&Backend::Cliclick, 5.0, 6.0, MouseButton::Right, false).unwrap();
    assert_eq!(as_strings(&args), vec!["rc:5,6"]);
}

#[test]
fn type_text_harness_input_uses_stdin_and_type_subcommand() {
    let backend = Backend::HarnessInput(PathBuf::from("/tmp/helper"));
    let (program, args) = type_text_args(&backend, "hello").unwrap();
    assert_eq!(program, OsString::from("/tmp/helper"));
    assert_eq!(as_strings(&args), vec!["type"]);
}

#[test]
fn type_text_cliclick_embeds_text_in_t_argument() {
    let (program, args) = type_text_args(&Backend::Cliclick, "hi").unwrap();
    assert_eq!(program, OsString::from("cliclick"));
    assert_eq!(as_strings(&args), vec!["t:hi"]);
}

#[test]
fn type_text_none_falls_back_to_osascript_keystroke() {
    let (program, args) = type_text_args(&Backend::None, "a\"b").unwrap();
    assert_eq!(program, OsString::from("/usr/bin/osascript"));
    assert_eq!(args.len(), 2);
    assert_eq!(args[0], OsString::from("-e"));
    let script = args[1].to_string_lossy();
    assert!(script.contains("keystroke \"a\\\"b\""), "got {script}");
}

#[test]
fn accessibility_list_elements_args_include_optional_filters() {
    let args = list_elements_args(Some(42), Some(ElementKind::Button));
    assert_eq!(
        as_strings(&args),
        vec!["list-elements", "--window-id", "42", "--kind", "button"],
    );
}

#[test]
fn accessibility_get_element_args_preserve_identifier() {
    let args = get_element_args("harness.sidebar.new-session");
    assert_eq!(
        as_strings(&args),
        vec!["get-element", "harness.sidebar.new-session"],
    );
}

#[test]
fn screencapture_args_default_is_silent_png_no_target() {
    let path = PathBuf::from("/tmp/out.png");
    let args = screencapture_args(&ScreenshotOptions::default(), &path);
    assert_eq!(as_strings(&args), vec!["-x", "-t", "png", "/tmp/out.png"],);
}

#[test]
fn screencapture_args_window_id_uses_l_flag() {
    let path = PathBuf::from("/tmp/out.png");
    let args = screencapture_args(
        &ScreenshotOptions {
            window_id: Some(42),
            display_id: None,
            include_cursor: true,
        },
        &path,
    );
    assert_eq!(
        as_strings(&args),
        vec!["-x", "-t", "png", "-l", "42", "-C", "/tmp/out.png"],
    );
}

#[test]
fn screencapture_args_display_id_uses_d_flag_when_window_absent() {
    let path = PathBuf::from("/tmp/out.png");
    let args = screencapture_args(
        &ScreenshotOptions {
            window_id: None,
            display_id: Some(3),
            include_cursor: false,
        },
        &path,
    );
    assert_eq!(
        as_strings(&args),
        vec!["-x", "-t", "png", "-D", "3", "/tmp/out.png"],
    );
}

#[test]
fn screencapture_args_window_wins_over_display() {
    let path = PathBuf::from("/tmp/out.png");
    let args = screencapture_args(
        &ScreenshotOptions {
            window_id: Some(1),
            display_id: Some(2),
            include_cursor: false,
        },
        &path,
    );
    let strings = as_strings(&args);
    assert!(strings.iter().any(|s| s == "-l"));
    assert!(!strings.iter().any(|s| s == "-D"));
}

#[tokio::test]
async fn detect_backend_honours_env_override_when_file_exists() {
    let temp = tempfile::tempdir().expect("tempdir");
    let expected_path = temp.path().join("harness-monitor-input");
    write_helper_script(&expected_path, valid_helper_script());
    let path_value = expected_path.to_string_lossy().into_owned();
    let backend = temp_env::async_with_vars(
        [(INPUT_OVERRIDE_ENV, Some(path_value.as_str()))],
        async move { detect_backend().await },
    )
    .await;
    assert_eq!(backend, Backend::HarnessInput(expected_path));
}

#[tokio::test]
async fn default_helper_candidate_prefers_newest_platform_build() {
    let temp = tempfile::tempdir().expect("tempdir");
    let build_root = temp.path().join("mcp-servers/harness-monitor-registry/.build");
    let release = build_root.join("arm64-apple-macosx/release/harness-monitor-input");
    let debug = build_root.join("arm64-apple-macosx/debug/harness-monitor-input");
    write_helper_script(&release, valid_helper_script());
    thread::sleep(Duration::from_millis(20));
    write_helper_script(&debug, valid_helper_script());

    let candidate = default_helper_candidate_in(temp.path()).await;
    assert_eq!(candidate, Some(debug));
}

#[tokio::test]
async fn default_helper_candidate_skips_newer_non_viable_platform_build() {
    let temp = tempfile::tempdir().expect("tempdir");
    let build_root = temp.path().join("mcp-servers/harness-monitor-registry/.build");
    let release = build_root.join("arm64-apple-macosx/release/harness-monitor-input");
    let debug = build_root.join("arm64-apple-macosx/debug/harness-monitor-input");
    write_helper_script(&release, valid_helper_script());
    thread::sleep(Duration::from_millis(20));
    write_helper_script(&debug, failing_helper_script());

    let candidate = default_helper_candidate_in(temp.path()).await;
    assert_eq!(candidate, Some(release));
}

#[tokio::test]
async fn default_helper_candidate_prefers_newest_viable_candidate_across_search_roots() {
    let first_root = tempfile::tempdir().expect("first root");
    let second_root = tempfile::tempdir().expect("second root");
    let older = first_root
        .path()
        .join("mcp-servers/harness-monitor-registry/.build/arm64-apple-macosx/release/harness-monitor-input");
    let newer = second_root
        .path()
        .join("mcp-servers/harness-monitor-registry/.build/arm64-apple-macosx/debug/harness-monitor-input");
    write_helper_script(&older, valid_helper_script());
    thread::sleep(Duration::from_millis(20));
    write_helper_script(&newer, valid_helper_script());

    let candidate = default_helper_candidate_from_roots(&[
        first_root.path().to_path_buf(),
        second_root.path().to_path_buf(),
    ])
    .await;
    assert_eq!(candidate, Some(newer));
}

#[test]
fn helper_search_roots_include_executable_and_current_dir_ancestors_once() {
    let current_dir = PathBuf::from("/tmp/harness/worktrees/main/apps/harness-monitor-macos");
    let current_exe = PathBuf::from("/tmp/harness/target/debug/harness");

    let roots = helper_search_roots_from(Some(&current_dir), Some(&current_exe));

    assert_eq!(roots.first(), Some(&PathBuf::from("/tmp/harness/target/debug")));
    assert!(roots.contains(&PathBuf::from("/tmp/harness")));
    assert_eq!(
        roots.iter().filter(|root| **root == PathBuf::from("/tmp/harness")).count(),
        1
    );
}
