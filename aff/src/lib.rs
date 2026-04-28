pub mod cli;
pub mod command_intent;
pub mod hook_agent;
pub mod hook_payload;
pub mod hook_render;
mod policy_spec;
pub mod repo_policy;

pub fn run() -> Result<i32, String> {
    cli::run()
}
