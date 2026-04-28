pub mod cli;
pub mod command_intent;
mod config_patch;
pub mod hook_agent;
pub mod hook_payload;
pub mod hook_render;
mod policy_spec;
pub mod repo_policy;
pub mod setup;

pub fn run() -> Result<i32, String> {
    cli::run()
}
