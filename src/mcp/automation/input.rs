use std::ffi::OsString;
use std::path::Path;
use std::process::Stdio;

use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use super::backend::{Backend, detect_backend};
use super::error::AutomationError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
}

impl MouseButton {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
            Self::Middle => "middle",
        }
    }
}

/// Build the `(program, args)` pair to move the cursor to `(x, y)`.
///
/// Pure function; used by both the execution path and unit tests.
#[must_use]
pub fn move_mouse_args(backend: &Backend, x: f64, y: f64) -> Option<(OsString, Vec<OsString>)> {
    let px = round_to_string(x);
    let py = round_to_string(y);
    match backend {
        Backend::HarnessInput(path) => Some((
            os_string_from_path(path),
            vec![
                OsString::from("move"),
                OsString::from(px),
                OsString::from(py),
            ],
        )),
        Backend::Cliclick => Some((
            OsString::from("cliclick"),
            vec![OsString::from(format!("m:{px},{py}"))],
        )),
        Backend::None => None,
    }
}

/// Build the `(program, args)` pair to click at `(x, y)`.
#[must_use]
pub fn click_args(
    backend: &Backend,
    x: f64,
    y: f64,
    button: MouseButton,
    double_click: bool,
) -> Option<(OsString, Vec<OsString>)> {
    let px = round_to_string(x);
    let py = round_to_string(y);
    match backend {
        Backend::HarnessInput(path) => Some((os_string_from_path(path), {
            let mut args = vec![
                OsString::from("click"),
                OsString::from(&px),
                OsString::from(&py),
                OsString::from("--button"),
                OsString::from(button.as_wire()),
            ];
            if double_click {
                args.push(OsString::from("--double"));
            }
            args
        })),
        Backend::Cliclick => Some((
            OsString::from("cliclick"),
            cliclick_click_args(&px, &py, button, double_click),
        )),
        Backend::None => None,
    }
}

/// Build the `(program, args)` pair to scroll at `(x, y)` by the given deltas.
#[must_use]
pub fn scroll_args(
    backend: &Backend,
    x: f64,
    y: f64,
    delta_x: f64,
    delta_y: f64,
) -> Option<(OsString, Vec<OsString>)> {
    let px = round_to_string(x);
    let py = round_to_string(y);
    let dx = round_to_string(delta_x);
    let dy = round_to_string(delta_y);
    match backend {
        Backend::HarnessInput(path) => Some((
            os_string_from_path(path),
            vec![
                OsString::from("scroll"),
                OsString::from(px),
                OsString::from(py),
                OsString::from(dx),
                OsString::from(dy),
            ],
        )),
        Backend::Cliclick | Backend::None => None,
    }
}

/// Build the `(program, args)` pair to drag from `(start_x, start_y)` to
/// `(end_x, end_y)`.
#[must_use]
pub fn drag_drop_args(
    backend: &Backend,
    start_x: f64,
    start_y: f64,
    end_x: f64,
    end_y: f64,
    duration_ms: u64,
) -> Option<(OsString, Vec<OsString>)> {
    let sx = round_to_string(start_x);
    let sy = round_to_string(start_y);
    let ex = round_to_string(end_x);
    let ey = round_to_string(end_y);
    match backend {
        Backend::HarnessInput(path) => Some((
            os_string_from_path(path),
            vec![
                OsString::from("drag"),
                OsString::from(&sx),
                OsString::from(&sy),
                OsString::from(&ex),
                OsString::from(&ey),
                OsString::from("--duration-ms"),
                OsString::from(duration_ms.to_string()),
            ],
        )),
        Backend::Cliclick | Backend::None => None,
    }
}

fn cliclick_click_args(
    px: &str,
    py: &str,
    button: MouseButton,
    double_click: bool,
) -> Vec<OsString> {
    if double_click {
        return vec![OsString::from(format!("dc:{px},{py}"))];
    }
    let verb = match button {
        MouseButton::Right => "rc",
        _ => "c",
    };
    vec![OsString::from(format!("{verb}:{px},{py}"))]
}

/// Build the `(program, args)` pair to type text. When the backend is
/// `HarnessInput`, the text is fed via stdin (not as an argument) so it is
/// not captured by the returned argv.
#[must_use]
pub fn type_text_args(backend: &Backend, text: &str) -> Option<(OsString, Vec<OsString>)> {
    match backend {
        Backend::HarnessInput(path) => {
            Some((os_string_from_path(path), vec![OsString::from("type")]))
        }
        Backend::Cliclick => Some((
            OsString::from("cliclick"),
            vec![OsString::from(format!("t:{text}"))],
        )),
        Backend::None => None,
    }
}

/// Move the cursor to `(x, y)` via the detected backend.
///
/// # Errors
/// Returns `AutomationError` when no backend is available or when the
/// underlying command fails.
pub async fn move_mouse(x: f64, y: f64) -> Result<(), AutomationError> {
    let backend = detect_backend().await;
    let Some((program, args)) = move_mouse_args(&backend, x, y) else {
        return Err(AutomationError::MouseBackendMissing);
    };
    run_command(&program, &args).await
}

/// Click at `(x, y)` via the detected backend.
///
/// # Errors
/// Returns `AutomationError` on backend failure or unsupported middle-click.
pub async fn click(
    x: f64,
    y: f64,
    button: MouseButton,
    double_click: bool,
) -> Result<(), AutomationError> {
    if button == MouseButton::Middle {
        return Err(AutomationError::UnsupportedButton);
    }
    let backend = detect_backend().await;
    let Some((program, args)) = click_args(&backend, x, y, button, double_click) else {
        return Err(AutomationError::MouseBackendMissing);
    };
    run_command(&program, &args).await
}

/// Scroll at `(x, y)` by the provided deltas via the bundled helper.
///
/// # Errors
/// Returns `AutomationError` when the helper is unavailable or the command
/// fails.
pub async fn scroll(x: f64, y: f64, delta_x: f64, delta_y: f64) -> Result<(), AutomationError> {
    let backend = detect_backend().await;
    let Some((program, args)) = scroll_args(&backend, x, y, delta_x, delta_y) else {
        return Err(AutomationError::ScrollBackendMissing);
    };
    run_command(&program, &args).await
}

/// Drag from `(start_x, start_y)` to `(end_x, end_y)` via the bundled helper.
///
/// # Errors
/// Returns `AutomationError` when the helper is unavailable or the command
/// fails.
pub async fn drag_drop(
    start_x: f64,
    start_y: f64,
    end_x: f64,
    end_y: f64,
    duration_ms: u64,
) -> Result<(), AutomationError> {
    let backend = detect_backend().await;
    let Some((program, args)) =
        drag_drop_args(&backend, start_x, start_y, end_x, end_y, duration_ms)
    else {
        return Err(AutomationError::DragBackendMissing);
    };
    run_command(&program, &args).await
}

/// Type `text` into the focused window.
///
/// # Errors
/// Returns `AutomationError` when no text-input backend is available or when
/// the backend fails.
pub async fn type_text(text: &str) -> Result<(), AutomationError> {
    if text.is_empty() {
        return Ok(());
    }
    let backend = detect_backend().await;
    let Some((program, args)) = type_text_args(&backend, text) else {
        return Err(AutomationError::KeyboardBackendMissing);
    };
    match &backend {
        Backend::HarnessInput(_) => run_with_stdin(&program, &args, text).await,
        Backend::Cliclick => run_command(&program, &args).await,
        Backend::None => Err(AutomationError::KeyboardBackendMissing),
    }
}

async fn run_command(program: &OsString, args: &[OsString]) -> Result<(), AutomationError> {
    let output = Command::new(program)
        .args(args)
        .output()
        .await
        .map_err(|error| AutomationError::InputFailed {
            detail: error.to_string(),
        })?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    Err(AutomationError::from_backend_output(&stderr))
}

async fn run_with_stdin(
    program: &OsString,
    args: &[OsString],
    stdin_text: &str,
) -> Result<(), AutomationError> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| AutomationError::InputFailed {
            detail: error.to_string(),
        })?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| AutomationError::InputFailed {
            detail: "stdin pipe unavailable".into(),
        })?;
    stdin
        .write_all(stdin_text.as_bytes())
        .await
        .map_err(|error| AutomationError::InputFailed {
            detail: error.to_string(),
        })?;
    drop(stdin);
    let output = child
        .wait_with_output()
        .await
        .map_err(|error| AutomationError::InputFailed {
            detail: error.to_string(),
        })?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    Err(AutomationError::from_backend_output(&stderr))
}

fn round_to_string(value: f64) -> String {
    if !value.is_finite() {
        return "0".to_string();
    }
    // Coordinates originate from JSON numbers that the MCP server produces
    // and consumes as screen pixels. Clamping to i32 is more than enough
    // for any real display geometry; truncation outside that range would
    // itself be nonsensical, so we saturate.
    let clamped = value
        .round()
        .clamp(f64::from(i32::MIN), f64::from(i32::MAX));
    #[expect(
        clippy::cast_possible_truncation,
        reason = "value is clamped to i32::MIN..=i32::MAX immediately above"
    )]
    let as_int = clamped as i32;
    as_int.to_string()
}

fn os_string_from_path(path: &Path) -> OsString {
    path.as_os_str().to_owned()
}
