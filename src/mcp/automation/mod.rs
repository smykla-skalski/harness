//! macOS automation primitives: mouse input, keyboard input, and window
//! screenshots. Ports the Node.js `automation.ts` module.
//!
//! Mouse and keyboard events go through the bundled `harness-monitor-input`
//! Swift helper when available; `cliclick` is accepted as a fallback for
//! legacy setups. Screenshots use native macOS capture APIs.

mod accessibility;
mod backend;
mod error;
mod input;
mod screenshot;

#[cfg(test)]
mod tests;

pub use accessibility::{
    AccessibilityAction, AccessibilityActionError, AccessibilityQueryError,
    get_element as get_accessibility_element, get_element_args as accessibility_get_element_args,
    list_elements as list_accessibility_elements,
    list_elements_args as accessibility_list_elements_args,
    perform_action as perform_accessibility_action,
    perform_action_args as accessibility_perform_action_args,
};
pub use backend::{Backend, INPUT_OVERRIDE_ENV, detect_backend};
pub use error::AutomationError;
pub use input::{
    MouseButton, click_args, drag_drop_args, move_mouse_args, scroll_args, type_text_args,
};
pub use input::{click, drag_drop, move_mouse, scroll, type_text};
pub use screenshot::{ScreenshotOptions, ScreenshotTarget, screenshot, shareable_harness_window_ids};
