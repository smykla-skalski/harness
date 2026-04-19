//! macOS-specific MCP tool handlers that drive the Harness Monitor app.

use std::sync::Arc;

use crate::mcp::registry::RegistryClient;
use crate::mcp::tool::ToolRegistry;

mod click;
mod click_element;
mod get_element;
mod list_elements;
mod list_windows;
mod move_mouse;
mod screenshot_window;
mod shared;
mod type_text;

#[cfg(test)]
mod tests;

pub use click::ClickTool;
pub use click_element::ClickElementTool;
pub use get_element::GetElementTool;
pub use list_elements::ListElementsTool;
pub use list_windows::ListWindowsTool;
pub use move_mouse::MoveMouseTool;
pub use screenshot_window::ScreenshotWindowTool;
pub use type_text::TypeTextTool;

/// Register every automation tool against `registry`, sharing a single
/// `RegistryClient` for the registry-backed tools.
pub fn register_all(registry: &mut ToolRegistry, client: Arc<RegistryClient>) {
    registry.register(Box::new(ListWindowsTool::new(Arc::clone(&client))));
    registry.register(Box::new(ListElementsTool::new(Arc::clone(&client))));
    registry.register(Box::new(GetElementTool::new(Arc::clone(&client))));
    registry.register(Box::new(MoveMouseTool));
    registry.register(Box::new(ClickTool));
    registry.register(Box::new(ClickElementTool::new(client)));
    registry.register(Box::new(TypeTextTool));
    registry.register(Box::new(ScreenshotWindowTool));
}
