use std::io::{Read as _, stdin};

use clap::{Args, Parser, Subcommand};

use crate::hook_agent::HookAgent;
use crate::{hook_render, repo_policy, setup};

#[derive(Debug, Parser)]
#[command(name = "aff")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    #[command(name = "repo-policy", hide = true)]
    RepoPolicy(RepoPolicyArgs),
    #[command(name = "session-start", hide = true)]
    SessionStart(SessionStartArgs),
    Setup(SetupArgs),
}

#[derive(Debug, Args)]
struct RepoPolicyArgs {
    #[arg(long, value_enum)]
    agent: HookAgent,
}

#[derive(Debug, Args)]
struct SessionStartArgs {
    #[arg(long, value_enum)]
    agent: HookAgent,
}

#[derive(Debug, Args)]
struct SetupArgs {
    #[command(subcommand)]
    command: setup::SetupCommand,
}

pub fn run() -> Result<i32, String> {
    Cli::parse().execute()
}

impl Cli {
    fn execute(self) -> Result<i32, String> {
        match self.command {
            Command::RepoPolicy(args) => args.execute(),
            Command::SessionStart(args) => args.execute(),
            Command::Setup(args) => args.execute(),
        }
    }
}

impl RepoPolicyArgs {
    fn execute(self) -> Result<i32, String> {
        let payload = read_stdin_bytes()?;
        let rendered = repo_policy::pre_tool_use_output(self.agent, &payload)?;
        if !rendered.stdout.is_empty() {
            print!("{}", rendered.stdout);
        }
        Ok(rendered.exit_code)
    }
}

impl SessionStartArgs {
    fn execute(self) -> Result<i32, String> {
        let json = hook_render::render_session_start_output(
            self.agent,
            repo_policy::session_start_context(),
        )?;
        print!("{json}");
        Ok(0)
    }
}

impl SetupArgs {
    fn execute(self) -> Result<i32, String> {
        setup::run(self.command)
    }
}

fn read_stdin_bytes() -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    stdin()
        .read_to_end(&mut bytes)
        .map_err(|error| format!("failed to read stdin: {error}"))?;
    Ok(bytes)
}
