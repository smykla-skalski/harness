use std::io;
use std::path::{Path, PathBuf};

use crate::agents::acp::catalog::{AcpAgentDescriptor, AcpSpawnConfiguration};
use crate::agents::acp::connection::SpawnConfig;
use crate::agents::runtime::{AgentRuntime, runtime_for_name};
use crate::daemon::agent_acp::protocol::AcpSessionRequestConfig;
use crate::daemon::state::task_board_openrouter_token;
use crate::errors::{CliError, CliErrorKind};

const OPENROUTER_DESCRIPTOR_ID: &str = "openrouter";

pub(super) fn build_spawn_config(
    descriptor: &AcpAgentDescriptor,
    session_config: &AcpSessionRequestConfig,
    project_dir: &Path,
) -> Result<SpawnConfig, CliError> {
    let runtime = resolve_spawn_runtime(descriptor)?;
    let model = session_config.requested_model();
    let effort = session_config.requested_effort();
    ensure_delivery_path(
        descriptor,
        runtime,
        model,
        session_config.model_via_session(),
        "model",
    )?;
    ensure_delivery_path(
        descriptor,
        runtime,
        effort,
        session_config.effort_via_session(),
        "effort",
    )?;

    let mut args = descriptor.launch_args.clone();
    if !session_config.model_via_session() {
        push_model_args(&mut args, runtime, model);
    }
    if !session_config.effort_via_session() {
        push_effort_args(&mut args, runtime, effort);
    }
    args.extend(descriptor_credential_args(descriptor)?);
    let env_overrides = effort_env_overrides(session_config, runtime, effort);

    Ok(SpawnConfig {
        command: descriptor.launch_command.clone(),
        args,
        env_passthrough: descriptor.env_passthrough.clone(),
        env_overrides,
        working_dir: project_dir.to_path_buf(),
    })
}

/// Append per-descriptor secret arguments. Today only the `OpenRouter` shim
/// needs one (`--api-key-file PATH`); other catalog entries expect zero extra
/// args. The shim reads the file immediately and unlinks it, so the credential
/// never lives on disk longer than one `stat()` interval.
fn descriptor_credential_args(descriptor: &AcpAgentDescriptor) -> Result<Vec<String>, CliError> {
    if descriptor.id.as_str() != OPENROUTER_DESCRIPTOR_ID {
        return Ok(Vec::new());
    }
    let token = task_board_openrouter_token().ok_or_else(|| {
        CliErrorKind::workflow_io(
            "OpenRouter API key is not configured. Set it via Harness Monitor → Settings → OpenRouter or run `harness setup secrets set --kind openrouter`.",
        )
    })?;
    let path = write_openrouter_api_key_file(&token)?;
    Ok(vec![
        "--api-key-file".to_string(),
        path.display().to_string(),
    ])
}

/// Write the `OpenRouter` API key into a mode-0600 file inside a freshly-created
/// per-spawn random tempdir. The shim unlinks the file at startup. The
/// surrounding directory lingers until the OS or daemon shutdown sweeps it,
/// which is acceptable because the secret itself is gone after the unlink.
fn write_openrouter_api_key_file(token: &str) -> Result<PathBuf, CliError> {
    let dir = tempfile::Builder::new()
        .prefix("harness-openrouter-")
        .tempdir()
        .map_err(|err| {
            CliErrorKind::workflow_io(format!("create openrouter credential tempdir: {err}"))
        })?;
    let dir_path = dir.keep();
    let file_path = dir_path.join("api-key");
    write_credential_bytes(&file_path, token).map_err(|err| {
        CliErrorKind::workflow_io(format!(
            "write openrouter credential file `{}`: {err}",
            file_path.display()
        ))
    })?;
    Ok(file_path)
}

#[cfg(unix)]
fn write_credential_bytes(path: &Path, token: &str) -> io::Result<()> {
    use std::fs::OpenOptions;
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(token.as_bytes())?;
    file.sync_all()
}

#[cfg(not(unix))]
fn write_credential_bytes(path: &Path, token: &str) -> io::Result<()> {
    use std::fs;
    fs::write(path, token)
}

fn push_model_args(
    args: &mut Vec<String>,
    runtime: Option<&dyn AgentRuntime>,
    model: Option<&str>,
) {
    let (Some(runtime), Some(model)) = (runtime, model) else {
        return;
    };
    let Some(flag) = runtime.model_flag() else {
        return;
    };
    args.push(flag.to_string());
    args.push(model.to_string());
}

fn push_effort_args(
    args: &mut Vec<String>,
    runtime: Option<&dyn AgentRuntime>,
    effort: Option<&str>,
) {
    if let (Some(runtime), Some(effort)) = (runtime, effort) {
        args.extend(runtime.effort_args(effort));
    }
}

fn effort_env_overrides(
    session_config: &AcpSessionRequestConfig,
    runtime: Option<&dyn AgentRuntime>,
    effort: Option<&str>,
) -> Vec<(String, String)> {
    if session_config.effort_via_session() {
        return Vec::new();
    }
    match (runtime, effort) {
        (Some(runtime), Some(effort)) => runtime.effort_env(effort),
        _ => Vec::new(),
    }
}

fn resolve_spawn_runtime(
    descriptor: &AcpAgentDescriptor,
) -> Result<Option<&'static dyn AgentRuntime>, CliError> {
    match &descriptor.spawn_configuration {
        AcpSpawnConfiguration::DescriptorRuntime => Ok(runtime_for_name(descriptor.id.as_str())),
        AcpSpawnConfiguration::Runtime { name } => {
            runtime_for_name(name).map(Some).ok_or_else(|| {
                CliErrorKind::workflow_io(format!(
                    "ACP descriptor '{}' references unknown runtime '{}'",
                    descriptor.id, name
                ))
                .into()
            })
        }
        AcpSpawnConfiguration::None => Ok(None),
    }
}

fn ensure_delivery_path(
    descriptor: &AcpAgentDescriptor,
    runtime: Option<&'static dyn AgentRuntime>,
    requested: Option<&str>,
    via_session: bool,
    field_name: &str,
) -> Result<(), CliError> {
    if requested.is_none() || via_session || runtime.is_some() {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "ACP descriptor '{}' has no {field_name} delivery path for the requested session configuration",
        descriptor.id
    ))
    .into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::acp::catalog::{
        AcpSessionConfigOptionBinding, AcpSessionConfiguration, AcpSessionEffortTransport,
        AcpSessionModelTransport, DoctorProbe,
    };
    use crate::daemon::agent_acp::manager::AcpAgentStartRequest;

    fn descriptor(id: &str) -> AcpAgentDescriptor {
        AcpAgentDescriptor {
            id: id.to_string(),
            display_name: "Fake ACP".to_string(),
            capabilities: Vec::new(),
            launch_command: "fake-acp".to_string(),
            launch_args: vec!["--acp".to_string()],
            env_passthrough: Vec::new(),
            spawn_configuration: Default::default(),
            model_catalog: None,
            install_hint: None,
            session_configuration: Default::default(),
            doctor_probe: DoctorProbe {
                command: "fake-acp".to_string(),
                args: vec!["--version".to_string()],
            },
            prompt_timeout_seconds: None,
            excluded_from_initial_default: false,
            bundled_with_harness: false,
        }
    }

    #[test]
    fn build_spawn_config_skips_native_model_and_effort_injection_when_session_config_is_enabled() {
        let descriptor = AcpAgentDescriptor {
            id: "claude".to_string(),
            session_configuration: AcpSessionConfiguration {
                model: AcpSessionModelTransport::ConfigOption {
                    selector: AcpSessionConfigOptionBinding::default(),
                },
                effort: AcpSessionEffortTransport::ConfigOption {
                    selector: AcpSessionConfigOptionBinding::default(),
                },
            },
            ..descriptor("claude")
        };
        let request = AcpAgentStartRequest {
            model: Some("claude-sonnet-4-6".to_string()),
            effort: Some("high".to_string()),
            ..AcpAgentStartRequest::default()
        };
        let session_config = AcpSessionRequestConfig::from_request(&request, &descriptor);
        let spawn = build_spawn_config(&descriptor, &session_config, Path::new("/tmp"))
            .expect("build spawn config");

        assert_eq!(spawn.args, vec!["--acp"]);
        assert!(spawn.env_overrides.is_empty());
    }

    #[test]
    fn build_spawn_config_uses_explicit_runtime_mapping_when_descriptor_id_differs() {
        let descriptor = AcpAgentDescriptor {
            spawn_configuration: AcpSpawnConfiguration::Runtime {
                name: "claude".to_string(),
            },
            ..descriptor("claude-acp")
        };
        let request = AcpAgentStartRequest {
            model: Some("claude-sonnet-4-6".to_string()),
            effort: Some("high".to_string()),
            ..AcpAgentStartRequest::default()
        };
        let session_config = AcpSessionRequestConfig::from_request(&request, &descriptor);
        let spawn = build_spawn_config(&descriptor, &session_config, Path::new("/tmp"))
            .expect("build spawn config");

        assert_eq!(
            spawn.args,
            vec![
                "--acp".to_string(),
                "--model".to_string(),
                "claude-sonnet-4-6".to_string()
            ]
        );
        assert!(
            spawn
                .env_overrides
                .iter()
                .any(|(key, value)| key == "HARNESS_CLAUDE_THINKING_LEVEL" && value == "high")
        );
    }

    #[test]
    fn build_spawn_config_rejects_requested_model_without_spawn_or_session_delivery_path() {
        let descriptor = AcpAgentDescriptor {
            spawn_configuration: AcpSpawnConfiguration::None,
            ..descriptor("claude")
        };
        let request = AcpAgentStartRequest {
            model: Some("claude-sonnet-4-6".to_string()),
            ..AcpAgentStartRequest::default()
        };
        let session_config = AcpSessionRequestConfig::from_request(&request, &descriptor);
        let error = build_spawn_config(&descriptor, &session_config, Path::new("/tmp"))
            .expect_err("missing model delivery path should fail");

        assert!(format!("{error}").contains("model delivery path"));
    }

    #[test]
    fn descriptor_credential_args_empty_for_non_openrouter_descriptors() {
        for id in ["claude", "codex", "copilot", "gemini"] {
            let descriptor = descriptor(id);
            let args = descriptor_credential_args(&descriptor)
                .expect("non-openrouter descriptors never need credentials");
            assert!(
                args.is_empty(),
                "descriptor `{id}` unexpectedly produced credential args: {args:?}"
            );
        }
    }
}
