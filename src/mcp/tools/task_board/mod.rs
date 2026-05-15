mod flow;
mod items;
mod orchestrator;
mod policy;
mod support;

use crate::mcp::tool::ToolRegistry;

pub(super) fn register_all(registry: &mut ToolRegistry) {
    items::register(registry);
    flow::register(registry);
    orchestrator::register(registry);
    policy::register(registry);
}
