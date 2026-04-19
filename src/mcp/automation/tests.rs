use std::ffi::OsString;
use std::path::PathBuf;

use super::backend::{Backend, INPUT_OVERRIDE_ENV, detect_backend};
use super::input::{MouseButton, click_args, move_mouse_args, type_text_args};
use super::screenshot::{ScreenshotOptions, screencapture_args};

fn as_strings(args: &[OsString]) -> Vec<String> {
    args.iter()
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect()
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
fn screencapture_args_default_is_silent_png_no_target() {
    let path = PathBuf::from("/tmp/out.png");
    let args = screencapture_args(&ScreenshotOptions::default(), &path);
    assert_eq!(
        as_strings(&args),
        vec!["-x", "-t", "png", "/tmp/out.png"],
    );
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
    let temp = tempfile::NamedTempFile::new().expect("tempfile");
    let path_value = temp.path().to_string_lossy().into_owned();
    let expected_path = temp.path().to_path_buf();
    let backend = temp_env::async_with_vars(
        [(INPUT_OVERRIDE_ENV, Some(path_value.as_str()))],
        async move { detect_backend().await },
    )
    .await;
    assert_eq!(backend, Backend::HarnessInput(expected_path));
}
