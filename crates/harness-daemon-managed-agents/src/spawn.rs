use std::collections::BTreeMap;
use std::env::{join_paths, split_paths, var, var_os};
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use portable_pty::CommandBuilder;

use harness_agents::runtime::{
    AgentRuntime, InitialPromptDelivery, hook_agent_for_runtime_name, runtime_for_name,
};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_workspace::workspace::dirs_home;

use crate::model::{
    AgentTuiBackend, AgentTuiLaunchProfile, AgentTuiSize, AgentTuiSpawnSpec,
    PortablePtyAgentTuiBackend,
};
use crate::process::AgentTuiProcess;
use crate::{AgentTuiInput, AgentTuiKey, READINESS_TIMEOUT};

/// Resolve a runtime's launch profile and spawn it inside a PTY.
///
/// # Errors
/// Returns a workflow I/O or parse error when runtime bootstrap, PTY
/// allocation, or process spawning fails.
pub fn spawn_agent_tui_process(
    session_id: &str,
    tui_id: &str,
    profile: AgentTuiLaunchProfile,
    project_dir: &Path,
    size: AgentTuiSize,
    auto_join_prompt: Option<String>,
    effort: Option<&str>,
) -> Result<AgentTuiProcess, CliError> {
    ensure_runtime_bootstrap(&profile.runtime, project_dir)?;
    let mut env = BTreeMap::new();
    env.insert("HARNESS_SESSION_ID".to_string(), session_id.to_string());
    env.insert("HARNESS_AGENT_TUI_ID".to_string(), tui_id.to_string());
    let runtime = runtime_for_name(&profile.runtime);
    if let Some(effort) = effort.filter(|value| !value.is_empty())
        && let Some(runtime) = runtime
    {
        for (key, value) in runtime.effort_env(effort) {
            env.insert(key, value);
        }
    }
    let readiness_pattern = runtime.and_then(AgentRuntime::readiness_pattern);
    let prompt_delivery = runtime.map_or(
        InitialPromptDelivery::PtySend,
        AgentRuntime::initial_prompt_delivery,
    );
    let cli_prompt = match prompt_delivery {
        InitialPromptDelivery::CliPositional | InitialPromptDelivery::CliFlag(_) => {
            auto_join_prompt
        }
        InitialPromptDelivery::PtySend => None,
    };
    let screen_text_fallback = runtime.is_some_and(|runtime| {
        !runtime.supports_readiness_hook() && runtime.readiness_pattern().is_none()
    });
    let mut spec = AgentTuiSpawnSpec::new(profile, project_dir.to_path_buf(), env, size)?;
    spec.readiness_pattern = readiness_pattern;
    spec.prompt_delivery = prompt_delivery;
    spec.cli_prompt = cli_prompt;
    spec.screen_text_fallback = screen_text_fallback;
    PortablePtyAgentTuiBackend.spawn(spec)
}

fn map_hook_error(error: &CliError) -> CliError {
    CliErrorKind::workflow_io(format!("standalone hook setup failed: {error}")).into()
}

/// Write the standalone hook setup assets a runtime needs before it spawns.
///
/// # Errors
/// Returns a workflow parse or I/O error when the runtime is unsupported or
/// standalone hook setup fails.
pub fn ensure_runtime_bootstrap(runtime: &str, project_dir: &Path) -> Result<(), CliError> {
    let path_env = var("PATH").unwrap_or_default();
    harness_hook::setup::wrapper::main_with_home(
        project_dir,
        &path_env,
        &harness_workspace::workspace::host_home_dir(),
    )
    .map_err(|error| map_hook_error(&error))?;
    let agent = hook_agent_for_runtime_name(runtime).ok_or_else(|| {
        CliErrorKind::workflow_parse(format!("unsupported terminal agent runtime '{runtime}'"))
    })?;
    let _ = harness_hook::setup::wrapper::write_agent_bootstrap(project_dir, agent, &[])
        .map_err(|error| map_hook_error(&error))?;
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub fn wait_for_readiness(process: &AgentTuiProcess, runtime: &str, tui_id: &str) -> bool {
    if process.wait_ready(READINESS_TIMEOUT) {
        return true;
    }
    tracing::warn!(
        runtime = %runtime,
        tui_id = %tui_id,
        "terminal agent readiness timeout, sending join message anyway"
    );
    false
}

/// Wait for readiness, then send the auto-join prompt and the user's first
/// prompt. Used by both the direct and bridge deferred-join background threads.
///
/// Returns the first problem worth putting on the snapshot. A readiness timeout
/// still sends the prompts, but they land blind and the agent may miss them, so
/// the caller has to record it rather than leave a healthy-looking `Running`.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub fn deliver_deferred_prompts(
    process: &AgentTuiProcess,
    runtime: &str,
    tui_id: &str,
    pty_auto_join: Option<&str>,
    user_prompt: Option<&str>,
) -> Option<String> {
    if pty_auto_join.is_none() && user_prompt.is_none() {
        return None;
    }
    let mut problem = (!wait_for_readiness(process, runtime, tui_id)).then(|| {
        format!(
            "terminal agent never signaled readiness within {}s, so its session join may have been missed",
            READINESS_TIMEOUT.as_secs()
        )
    });
    if let Some(auto_join) = pty_auto_join
        && let Err(error) = send_initial_prompt(process, auto_join)
    {
        tracing::warn!(%error, tui_id = %tui_id, "deferred join: failed to send auto-join");
        return Some(format!("failed to send the session join: {error}"));
    }
    if let Some(prompt) = user_prompt
        && let Err(error) = send_initial_prompt(process, prompt)
    {
        tracing::warn!(%error, tui_id = %tui_id, "failed to send user prompt after auto-join");
        if problem.is_none() {
            problem = Some(format!("failed to send the initial prompt: {error}"));
        }
    }
    problem
}

/// Send a text prompt followed by Enter to a running terminal agent.
///
/// # Errors
/// Returns a workflow parse or I/O error when sending either input fails.
pub fn send_initial_prompt(process: &AgentTuiProcess, prompt: &str) -> Result<(), CliError> {
    process.send_input(&AgentTuiInput::Text {
        text: prompt.to_string(),
    })?;
    process.send_input(&AgentTuiInput::Key {
        key: AgentTuiKey::Enter,
    })
}

pub(crate) fn command_builder(spec: &AgentTuiSpawnSpec) -> CommandBuilder {
    let argv = resolved_command_argv(spec);
    let mut cmd = CommandBuilder::from_argv(argv);
    cmd.cwd(spec.project_dir.as_os_str());
    cmd.env("TERM", "xterm-256color");
    if let Some(path) = agent_tui_spawn_path(&spec.profile.runtime) {
        cmd.env("PATH", path);
    }
    for (key, value) in &spec.env {
        cmd.env(key, value);
    }
    cmd
}

pub fn resolved_command_argv(spec: &AgentTuiSpawnSpec) -> Vec<OsString> {
    let mut argv = spec
        .profile
        .argv
        .iter()
        .map(OsString::from)
        .collect::<Vec<_>>();
    let Some(program) = spec.profile.argv.first() else {
        return argv;
    };
    if let Some(resolved) = resolve_agent_tui_program(&spec.profile.runtime, program) {
        argv[0] = resolved.into_os_string();
    }
    if let Some(prompt) = &spec.cli_prompt {
        match spec.prompt_delivery {
            InitialPromptDelivery::CliPositional => argv.push(OsString::from(prompt)),
            InitialPromptDelivery::CliFlag(flag) => {
                argv.push(OsString::from(flag));
                argv.push(OsString::from(prompt));
            }
            InitialPromptDelivery::PtySend => {}
        }
    }
    argv
}

fn resolve_agent_tui_program(runtime: &str, program: &str) -> Option<PathBuf> {
    let path = Path::new(program);
    if path.is_absolute() || program.contains('/') {
        return is_executable(path).then(|| path.to_path_buf());
    }

    agent_tui_search_dirs(runtime)
        .into_iter()
        .find_map(|directory| {
            let candidate = directory.join(program);
            is_executable(&candidate).then_some(candidate)
        })
}

fn agent_tui_spawn_path(runtime: &str) -> Option<OsString> {
    let dirs = agent_tui_search_dirs(runtime);
    (!dirs.is_empty()).then(|| join_paths(dirs).expect("terminal agent PATH entries serialize"))
}

fn agent_tui_search_dirs(runtime: &str) -> Vec<PathBuf> {
    let home = dirs_home();
    let mut dirs = vec![home.join(".local").join("bin"), home.join("bin")];
    match runtime {
        "vibe" => {
            dirs.push(
                home.join(".local")
                    .join("share")
                    .join("uv")
                    .join("tools")
                    .join("mistral-vibe")
                    .join("bin"),
            );
        }
        "opencode" => dirs.push(home.join(".opencode").join("bin")),
        _ => {}
    }
    if let Some(path_env) = var_os("PATH") {
        for directory in split_paths(&path_env) {
            push_unique_path(&mut dirs, directory);
        }
    }
    dirs
}

fn push_unique_path(dirs: &mut Vec<PathBuf>, candidate: PathBuf) {
    if candidate.as_os_str().is_empty() || dirs.iter().any(|existing| existing == &candidate) {
        return;
    }
    dirs.push(candidate);
}

fn is_executable(path: &Path) -> bool {
    path.metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}
