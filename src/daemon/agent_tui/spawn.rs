use std::collections::BTreeMap;
use std::env::{join_paths, split_paths, var_os};
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use portable_pty::CommandBuilder;

use crate::agents::runtime::{
    AgentRuntime, InitialPromptDelivery, hook_agent_for_runtime_name, runtime_for_name,
};
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::SessionRole;
use crate::setup::wrapper;
use crate::workspace::dirs_home;

use super::READINESS_TIMEOUT;
use super::input::{AgentTuiInput, AgentTuiKey};
use super::model::{
    AgentTuiBackend, AgentTuiLaunchProfile, AgentTuiSize, AgentTuiSpawnSpec,
    PortablePtyAgentTuiBackend,
};
use super::process::AgentTuiProcess;

pub(crate) fn spawn_agent_tui_process(
    session_id: &str,
    tui_id: &str,
    profile: AgentTuiLaunchProfile,
    project_dir: &Path,
    size: AgentTuiSize,
    auto_join_prompt: Option<String>,
) -> Result<AgentTuiProcess, CliError> {
    ensure_runtime_bootstrap(&profile.runtime, project_dir)?;
    let mut env = BTreeMap::new();
    env.insert("HARNESS_SESSION_ID".to_string(), session_id.to_string());
    env.insert("HARNESS_AGENT_TUI_ID".to_string(), tui_id.to_string());
    let runtime = runtime_for_name(&profile.runtime);
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

pub(crate) fn ensure_runtime_bootstrap(runtime: &str, project_dir: &Path) -> Result<(), CliError> {
    let path_env = std::env::var("PATH").unwrap_or_default();
    wrapper::main(project_dir, &path_env)?;
    let agent = hook_agent_for_runtime_name(runtime).ok_or_else(|| {
        CliErrorKind::workflow_parse(format!("unsupported agent TUI runtime '{runtime}'"))
    })?;
    let _ = wrapper::write_agent_bootstrap(project_dir, agent)?;
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(crate) fn wait_for_readiness(process: &AgentTuiProcess, runtime: &str, tui_id: &str) {
    if !process.wait_ready(READINESS_TIMEOUT) {
        tracing::warn!(
            runtime = %runtime,
            tui_id = %tui_id,
            "agent TUI readiness timeout, sending join message anyway"
        );
    }
}

/// Wait for readiness, then send the auto-join prompt and optional user prompt.
/// Used by both the direct and bridge deferred-join background threads.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(crate) fn deliver_deferred_prompts(
    process: &AgentTuiProcess,
    runtime: &str,
    tui_id: &str,
    auto_join: &str,
    user_prompt: Option<&str>,
) {
    wait_for_readiness(process, runtime, tui_id);
    if let Err(error) = send_initial_prompt(process, auto_join) {
        tracing::warn!(%error, tui_id = %tui_id, "deferred join: failed to send auto-join");
        return;
    }
    if let Some(prompt) = user_prompt
        && let Err(error) = send_initial_prompt(process, prompt)
    {
        tracing::warn!(%error, "failed to send user prompt after auto-join");
    }
}

pub(crate) fn send_initial_prompt(process: &AgentTuiProcess, prompt: &str) -> Result<(), CliError> {
    process.send_input(&AgentTuiInput::Text {
        text: prompt.to_string(),
    })?;
    process.send_input(&AgentTuiInput::Key {
        key: AgentTuiKey::Enter,
    })
}

/// Build the skill invocation string that the daemon sends as the first PTY
/// input so the agent auto-joins the session.
#[expect(
    clippy::too_many_arguments,
    reason = "auto-join prompt generation needs to thread join flags explicitly"
)]
pub(crate) fn build_auto_join_prompt(
    runtime: &str,
    session_id: &str,
    role: SessionRole,
    fallback_role: Option<SessionRole>,
    capabilities: &[String],
    tui_id: &str,
    name: Option<&str>,
    persona: Option<&str>,
) -> String {
    let mut caps: Vec<&str> = capabilities.iter().map(String::as_str).collect();
    let marker = format!("agent-tui:{tui_id}");
    for capability in ["agent-tui", marker.as_str()] {
        if !caps.contains(&capability) {
            caps.push(capability);
        }
    }
    let caps_joined = caps.join(",");

    let role_str = match role {
        SessionRole::Leader => "leader",
        SessionRole::Worker => "worker",
        SessionRole::Observer => "observer",
        SessionRole::Reviewer => "reviewer",
        SessionRole::Improver => "improver",
    };

    let name_flag = name.map_or_else(String::new, |value| format!(" --name \"{value}\""));
    let persona_flag = persona.map_or_else(String::new, |value| format!(" --persona \"{value}\""));
    let fallback_role_flag = fallback_role.map_or_else(String::new, |value| {
        let value = match value {
            SessionRole::Leader => "leader",
            SessionRole::Worker => "worker",
            SessionRole::Observer => "observer",
            SessionRole::Reviewer => "reviewer",
            SessionRole::Improver => "improver",
        };
        format!(" --fallback-role {value}")
    });

    format!(
        "/harness:session:join {session_id} --role {role_str} --runtime {runtime} --capabilities \"{caps_joined}\"{fallback_role_flag}{name_flag}{persona_flag}"
    )
}

/// Return per-runtime argv entries that make the harness session plugin
/// discoverable when the agent TUI starts.
pub(crate) fn skill_directory_flags(runtime: &str, project_dir: &Path) -> Vec<String> {
    match runtime {
        "claude" => {
            let plugin_dir = project_dir.join(".claude").join("plugins").join("harness");
            if plugin_dir.is_dir() {
                vec!["--plugin-dir".to_string(), plugin_dir.display().to_string()]
            } else {
                vec![]
            }
        }
        "copilot" => {
            let plugin_dir = project_dir.join("plugins").join("harness");
            if plugin_dir.is_dir() {
                vec!["--plugin-dir".to_string(), plugin_dir.display().to_string()]
            } else {
                vec![]
            }
        }
        _ => vec![],
    }
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

pub(crate) fn resolved_command_argv(spec: &AgentTuiSpawnSpec) -> Vec<OsString> {
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
    for flag in skill_directory_flags(&spec.profile.runtime, &spec.project_dir) {
        argv.push(OsString::from(flag));
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
    (!dirs.is_empty()).then(|| join_paths(dirs).expect("agent TUI PATH entries serialize"))
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
