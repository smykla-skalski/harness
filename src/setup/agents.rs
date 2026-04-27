use clap::{Args, Subcommand};

use crate::agents::assets::{AgentAssetTarget, generate_agent_assets_with_skipped_runtime_hooks};
use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::feature_flags::RuntimeHookFlags;
use crate::hooks::adapters::HookAgent;

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum AgentsSetupCommand {
    /// Generate checked-in multi-agent skills and plugin assets.
    Generate(GenerateAgentAssetsArgs),
}

impl Execute for AgentsSetupCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Generate(args) => args.execute(context),
        }
    }
}

#[derive(Debug, Clone, Args)]
pub struct GenerateAgentAssetsArgs {
    /// Fail if generated output differs from the checked-in files.
    #[arg(long)]
    pub check: bool,
    /// Also emit Gemini `.gemini/commands/**` command wrappers.
    #[arg(long)]
    pub include_gemini_commands: bool,
    /// Limit generation to a single target.
    #[arg(long, value_enum, default_value_t = AgentAssetTarget::All)]
    pub target: AgentAssetTarget,
    /// Skip runtime hook config files for the listed agents while generating.
    #[arg(long, value_enum, value_delimiter = ',', num_args = 1..)]
    pub skip_runtime_hooks: Vec<HookAgent>,
    #[command(flatten)]
    pub hook_flags: GenerateAgentHookFlags,
}

#[derive(Debug, Clone, Args, Default)]
pub struct GenerateAgentHookFlags {
    /// Re-enable the suite-lifecycle hooks (`guard-stop`, `context-agent`,
    /// `validate-agent`, `tool-failure`) that are off by default while the
    /// suite workflow is unfinished. Equivalent to `HARNESS_FEATURE_SUITE_HOOKS=1`.
    #[arg(long)]
    pub enable_suite_hooks: bool,
    /// Re-enable the `repo-policy` pre-tool hook that warns about raw
    /// `cargo`/`xcodebuild` usage in mise-driven repos. Off by default.
    /// Equivalent to `HARNESS_FEATURE_REPO_POLICY=1`.
    #[arg(long)]
    pub enable_repo_policy: bool,
}

impl Execute for GenerateAgentAssetsArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let suite = self.hook_flags.enable_suite_hooks.then_some(true);
        let repo_policy = self.hook_flags.enable_repo_policy.then_some(true);
        generate_agent_assets_with_skipped_runtime_hooks(
            self.target,
            self.check,
            &self.skip_runtime_hooks,
            self.include_gemini_commands,
            RuntimeHookFlags::resolve(suite, repo_policy),
        )
    }
}
