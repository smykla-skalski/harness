use std::sync::LazyLock;

mod build;
mod cli;
mod coordination;
mod hook;
mod integrity;
mod skill;
mod subagent;
mod tool;
mod unexpected;
mod user;
mod workflow;

use super::IssueCodeMeta;

pub(super) static ISSUE_CODE_REGISTRY: LazyLock<Box<[IssueCodeMeta]>> = LazyLock::new(|| {
    let mut registry = Vec::new();
    registry.extend_from_slice(hook::ISSUE_CODE_METAS);
    registry.extend_from_slice(build::ISSUE_CODE_METAS);
    registry.extend_from_slice(cli::ISSUE_CODE_METAS);
    registry.extend_from_slice(integrity::ISSUE_CODE_METAS);
    registry.extend_from_slice(skill::ISSUE_CODE_METAS);
    registry.extend_from_slice(subagent::ISSUE_CODE_METAS);
    registry.extend_from_slice(tool::ISSUE_CODE_METAS);
    registry.extend_from_slice(unexpected::ISSUE_CODE_METAS);
    registry.extend_from_slice(user::ISSUE_CODE_METAS);
    registry.extend_from_slice(workflow::ISSUE_CODE_METAS);
    registry.extend_from_slice(coordination::ISSUE_CODE_METAS);
    registry.into_boxed_slice()
});
