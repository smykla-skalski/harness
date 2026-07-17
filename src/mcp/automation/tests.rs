use std::collections::HashSet;
use std::ffi::OsString;
use std::fs;
use std::future::{Ready, ready};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use std::os::unix::fs::PermissionsExt;
use tokio::sync::Barrier;

use crate::mcp::automation::AccessibilityAction;
use crate::mcp::registry::ElementKind;

use super::accessibility::{get_element_args, list_elements_args, perform_action_args};
use super::backend::{
    Backend, INPUT_OVERRIDE_ENV, default_helper_candidate_from_roots_with_probe,
    detect_backend_with_probe, helper_search_roots_from, viable_helper_candidate_with_launch_check,
};
use super::input::{MouseButton, click_args, move_mouse_args, type_text_args};
use super::screenshot::{ScreenshotOptions, ScreenshotTarget, screenshot_args};

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

fn set_helper_modified(path: &Path, seconds: u64) {
    let file = fs::OpenOptions::new()
        .write(true)
        .open(path)
        .expect("open helper for timestamp update");
    file.set_times(
        fs::FileTimes::new().set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(seconds)),
    )
    .expect("set helper timestamp");
}

fn valid_helper_script() -> &'static str {
    "#!/bin/sh\nexit 0\n"
}

fn failing_helper_script() -> &'static str {
    "#!/bin/sh\nexit 1\n"
}

fn probe_fixture_candidate(
    viable: &HashSet<PathBuf>,
    path: PathBuf,
) -> Ready<Option<(SystemTime, PathBuf)>> {
    let candidate = viable.contains(&path).then(|| {
        let modified = fs::metadata(&path)
            .expect("candidate metadata")
            .modified()
            .expect("candidate timestamp");
        (modified, path)
    });
    ready(candidate)
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
fn type_text_none_has_no_backend() {
    assert!(type_text_args(&Backend::None, "a\"b").is_none());
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
    let args = get_element_args("harness.sidebar.a3c901ec-c08e-5e74-a877-3802a9410c55ion");
    assert_eq!(
        as_strings(&args),
        vec![
            "get-element",
            "harness.sidebar.a3c901ec-c08e-5e74-a877-3802a9410c55ion"
        ],
    );
}

#[test]
fn accessibility_perform_action_args_include_window_and_action() {
    let args = perform_action_args(
        "harness.sidebar.a3c901ec-c08e-5e74-a877-3802a9410c55ion",
        Some(42),
        AccessibilityAction::Press,
    );
    assert_eq!(
        as_strings(&args),
        vec![
            "perform-action",
            "--window-id",
            "42",
            "--action",
            "press",
            "harness.sidebar.a3c901ec-c08e-5e74-a877-3802a9410c55ion",
        ],
    );
}

#[test]
fn screenshot_target_defaults_to_main_display() {
    assert_eq!(
        ScreenshotOptions::default().target(),
        ScreenshotTarget::MainDisplay
    );
}

#[test]
fn screenshot_target_uses_window_when_present() {
    assert_eq!(
        ScreenshotOptions {
            window_id: Some(42),
            window_ids: vec![],
            display_id: Some(3),
            include_cursor: false,
        }
        .target(),
        ScreenshotTarget::Window(42)
    );
}

#[test]
fn screenshot_target_uses_display_when_window_absent() {
    assert_eq!(
        ScreenshotOptions {
            window_id: None,
            window_ids: vec![],
            display_id: Some(3),
            include_cursor: false,
        }
        .target(),
        ScreenshotTarget::Display(3)
    );
}

#[test]
fn screenshot_args_prefer_window_and_pass_cursor_flag() {
    let backend = Backend::HarnessInput(PathBuf::from("/tmp/helper"));
    let (_, args) = screenshot_args(
        &backend,
        &ScreenshotOptions {
            window_id: Some(42),
            window_ids: vec![],
            display_id: Some(3),
            include_cursor: true,
        },
    )
    .expect("helper backend available");
    assert_eq!(
        as_strings(&args),
        vec!["screenshot", "--window-id", "42", "--include-cursor"],
    );
}

#[test]
fn screenshot_args_use_display_when_window_absent() {
    let backend = Backend::HarnessInput(PathBuf::from("/tmp/helper"));
    let (_, args) = screenshot_args(
        &backend,
        &ScreenshotOptions {
            window_id: None,
            window_ids: vec![],
            display_id: Some(3),
            include_cursor: false,
        },
    )
    .expect("helper backend available");
    assert_eq!(as_strings(&args), vec!["screenshot", "--display-id", "3"]);
}

#[test]
fn screenshot_args_repeat_explicit_window_ids_and_keep_display_filter() {
    let backend = Backend::HarnessInput(PathBuf::from("/tmp/helper"));
    let (_, args) = screenshot_args(
        &backend,
        &ScreenshotOptions {
            window_id: None,
            window_ids: vec![42, 43],
            display_id: Some(7),
            include_cursor: false,
        },
    )
    .expect("helper backend available");
    assert_eq!(
        as_strings(&args),
        vec![
            "screenshot",
            "--window-id",
            "42",
            "--window-id",
            "43",
            "--display-id",
            "7",
        ],
    );
}

#[test]
fn screenshot_args_require_harness_input_backend() {
    assert!(screenshot_args(&Backend::Cliclick, &ScreenshotOptions::default()).is_none());
    assert!(screenshot_args(&Backend::None, &ScreenshotOptions::default()).is_none());
}

#[tokio::test]
async fn detect_backend_honours_env_override_when_file_exists() {
    let temp = tempfile::tempdir().expect("tempdir");
    let expected_path = temp.path().join("harness-monitor-input");
    write_helper_script(&expected_path, valid_helper_script());
    let path_value = expected_path.to_string_lossy().into_owned();
    let expected_for_probe = expected_path.clone();
    let backend =
        temp_env::async_with_vars([(INPUT_OVERRIDE_ENV, Some(path_value.as_str()))], async {
            let mut probe = move |path: PathBuf| {
                ready((path == expected_for_probe).then_some((SystemTime::UNIX_EPOCH, path)))
            };
            detect_backend_with_probe(&mut probe).await
        })
        .await;
    assert_eq!(backend, Backend::HarnessInput(expected_path));
}

#[tokio::test]
async fn helper_candidate_requires_executable_metadata_and_a_successful_launch() {
    let temp = tempfile::tempdir().expect("tempdir");
    let missing = temp.path().join("missing-helper");
    let mut successful_launch = |_| ready(true);
    assert!(
        viable_helper_candidate_with_launch_check(&missing, &mut successful_launch)
            .await
            .is_none()
    );

    let helper = temp.path().join("harness-monitor-input");
    write_helper_script(&helper, valid_helper_script());
    let mut failed_launch = |_| ready(false);
    assert!(
        viable_helper_candidate_with_launch_check(&helper, &mut failed_launch)
            .await
            .is_none()
    );

    let mut successful_launch = |_| ready(true);
    let viable = viable_helper_candidate_with_launch_check(&helper, &mut successful_launch).await;
    assert_eq!(viable.map(|(_, path)| path), Some(helper.clone()));

    let mut permissions = fs::metadata(&helper)
        .expect("helper metadata")
        .permissions();
    permissions.set_mode(0o644);
    fs::set_permissions(&helper, permissions).expect("remove executable bit");
    let mut successful_launch = |_| ready(true);
    assert!(
        viable_helper_candidate_with_launch_check(&helper, &mut successful_launch)
            .await
            .is_none()
    );
}

#[tokio::test]
async fn default_helper_candidate_prefers_newest_platform_build() {
    let temp = tempfile::tempdir().expect("tempdir");
    let build_root = temp
        .path()
        .join("mcp-servers/harness-monitor-registry/.build");
    let release = build_root.join("arm64-apple-macosx/release/harness-monitor-input");
    let debug = build_root.join("arm64-apple-macosx/debug/harness-monitor-input");
    write_helper_script(&release, valid_helper_script());
    write_helper_script(&debug, valid_helper_script());
    set_helper_modified(&release, 1);
    set_helper_modified(&debug, 2);

    let viable = HashSet::from([release.clone(), debug.clone()]);
    let mut probe = |path| probe_fixture_candidate(&viable, path);
    let candidate =
        default_helper_candidate_from_roots_with_probe(&[temp.path().to_path_buf()], &mut probe)
            .await;
    assert_eq!(candidate, Some(debug));
}

#[tokio::test]
async fn default_helper_candidate_skips_newer_non_viable_platform_build() {
    let temp = tempfile::tempdir().expect("tempdir");
    let build_root = temp
        .path()
        .join("mcp-servers/harness-monitor-registry/.build");
    let release = build_root.join("arm64-apple-macosx/release/harness-monitor-input");
    let debug = build_root.join("arm64-apple-macosx/debug/harness-monitor-input");
    write_helper_script(&release, valid_helper_script());
    write_helper_script(&debug, failing_helper_script());
    set_helper_modified(&release, 1);
    set_helper_modified(&debug, 2);

    let viable = HashSet::from([release.clone()]);
    let mut probe = |path| probe_fixture_candidate(&viable, path);
    let candidate =
        default_helper_candidate_from_roots_with_probe(&[temp.path().to_path_buf()], &mut probe)
            .await;
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
    write_helper_script(&newer, valid_helper_script());
    set_helper_modified(&older, 1);
    set_helper_modified(&newer, 2);

    let viable = HashSet::from([older.clone(), newer.clone()]);
    let mut probe = |path| probe_fixture_candidate(&viable, path);
    let candidate = default_helper_candidate_from_roots_with_probe(
        &[
            first_root.path().to_path_buf(),
            second_root.path().to_path_buf(),
        ],
        &mut probe,
    )
    .await;
    assert_eq!(candidate, Some(newer));
}

#[tokio::test]
async fn concurrent_helper_discovery_keeps_injected_probe_results_isolated() {
    let first_root = tempfile::tempdir().expect("first root");
    let second_root = tempfile::tempdir().expect("second root");
    let first = first_root
        .path()
        .join("mcp-servers/harness-monitor-registry/.build/arm64-apple-macosx/release/harness-monitor-input");
    let second = second_root
        .path()
        .join("mcp-servers/harness-monitor-registry/.build/arm64-apple-macosx/release/harness-monitor-input");
    write_helper_script(&first, valid_helper_script());
    write_helper_script(&second, valid_helper_script());
    let barrier = Arc::new(Barrier::new(2));

    let discover = |root: PathBuf, expected: PathBuf, barrier: Arc<Barrier>| async move {
        let viable = HashSet::from([expected]);
        let mut probe = move |path| {
            let candidate = probe_fixture_candidate(&viable, path);
            let barrier = Arc::clone(&barrier);
            async move {
                barrier.wait().await;
                candidate.await
            }
        };
        default_helper_candidate_from_roots_with_probe(&[root], &mut probe).await
    };

    let (first_result, second_result) = tokio::join!(
        discover(
            first_root.path().to_path_buf(),
            first.clone(),
            Arc::clone(&barrier),
        ),
        discover(second_root.path().to_path_buf(), second.clone(), barrier,),
    );

    assert_eq!(first_result, Some(first));
    assert_eq!(second_result, Some(second));
}

#[test]
fn helper_search_roots_include_executable_and_current_dir_ancestors_once() {
    let current_dir = PathBuf::from("/tmp/harness/worktrees/main/apps/harness-monitor");
    let current_exe = PathBuf::from("/tmp/harness/target/debug/harness");
    let repo_root = Path::new("/tmp/harness");

    let roots = helper_search_roots_from(Some(&current_dir), Some(&current_exe));

    assert_eq!(
        roots.first(),
        Some(&PathBuf::from("/tmp/harness/target/debug"))
    );
    assert!(roots.iter().any(|root| root.as_path() == repo_root));
    assert_eq!(
        roots
            .iter()
            .filter(|root| root.as_path() == repo_root)
            .count(),
        1
    );
}
