//! macOS automation primitives: mouse input, keyboard input, and window
//! screenshots. Ports the Node.js `automation.ts` module.
//!
//! Mouse and keyboard events go through the bundled `harness-monitor-input`
//! Swift helper when available; `cliclick` is accepted as a fallback for
//! legacy setups; `osascript` covers text input when neither helper is
//! present. Screenshots always use `/usr/sbin/screencapture`.

mod backend;
mod error;
mod input;
mod screenshot;

#[cfg(test)]
mod tests;

pub use backend::{Backend, INPUT_OVERRIDE_ENV, detect_backend};
pub use error::AutomationError;
pub use input::{MouseButton, click_args, move_mouse_args, type_text_args};
pub use input::{click, move_mouse, type_text};
pub use screenshot::{ScreenshotOptions, screencapture_args, screenshot};
