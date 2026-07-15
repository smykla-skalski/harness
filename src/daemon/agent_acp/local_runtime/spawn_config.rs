use std::path::Path;

use crate::agents::acp::catalog::{AcpAgentDescriptor, AcpSpawnConfiguration};
use crate::agents::acp::connection::SpawnConfig;
use crate::agents::runtime::{AgentRuntime, runtime_for_name};
use crate::daemon::agent_acp::protocol::AcpSessionRequestConfig;
use crate::daemon::agent_acp::spawn_credential::SpawnCredential;
use crate::errors::{CliError, CliErrorKind};

const OPENROUTER_DESCRIPTOR_ID: &str = "openrouter";

pub(super) fn build_spawn_config(
    descriptor: &AcpAgentDescriptor,
    session_config: &AcpSessionRequestConfig,
    project_dir: &Path,
    openrouter_token: Option<&str>,
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
    validate_descriptor_credential(descriptor, openrouter_token)?;
    let env_overrides = effort_env_overrides(session_config, runtime, effort);

    Ok(SpawnConfig {
        command: descriptor.launch_command.clone(),
        args,
        env_passthrough: descriptor.env_passthrough.clone(),
        env_overrides,
        working_dir: project_dir.to_path_buf(),
    })
}

/// Create the one-shot credential only after process-pool reuse is ruled out.
pub(super) fn prepare_spawn_credential(
    spawn: &mut SpawnConfig,
    descriptor: &AcpAgentDescriptor,
    openrouter_token: Option<&str>,
) -> Result<Option<SpawnCredential>, CliError> {
    validate_descriptor_credential(descriptor, openrouter_token)?;
    if descriptor.id.as_str() != OPENROUTER_DESCRIPTOR_ID {
        return Ok(None);
    }
    let credential = SpawnCredential::openrouter(openrouter_token.expect("validated token"))?;
    spawn.args.push("--api-key-file".to_string());
    spawn.args.push(credential.path().display().to_string());
    Ok(Some(credential))
}

fn validate_descriptor_credential(
    descriptor: &AcpAgentDescriptor,
    openrouter_token: Option<&str>,
) -> Result<(), CliError> {
    if descriptor.id.as_str() != OPENROUTER_DESCRIPTOR_ID {
        return openrouter_token.map_or(Ok(()), |_| {
            Err(CliErrorKind::workflow_parse(format!(
                "OpenRouter credential cannot be used with ACP descriptor '{}'",
                descriptor.id
            ))
            .into())
        });
    }
    openrouter_token.map_or_else(
        || {
            Err(CliErrorKind::workflow_io(
                "OpenRouter API key is not configured. Set it via Harness Monitor → Settings → OpenRouter or run `harness setup secrets set --kind openrouter`.",
            )
            .into())
        },
        |_| Ok(()),
    )
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
        let spawn = build_spawn_config(&descriptor, &session_config, Path::new("/tmp"), None)
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
        let spawn = build_spawn_config(&descriptor, &session_config, Path::new("/tmp"), None)
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
        let error = build_spawn_config(&descriptor, &session_config, Path::new("/tmp"), None)
            .expect_err("missing model delivery path should fail");

        assert!(format!("{error}").contains("model delivery path"));
    }

    #[test]
    fn descriptor_credential_is_absent_for_non_openrouter_descriptors() {
        for id in ["claude", "codex", "copilot", "gemini"] {
            let descriptor = descriptor(id);
            let mut spawn = SpawnConfig {
                command: descriptor.launch_command.clone(),
                args: descriptor.launch_args.clone(),
                env_passthrough: Vec::new(),
                env_overrides: Vec::new(),
                working_dir: Path::new("/tmp").to_path_buf(),
            };
            let credential = prepare_spawn_credential(&mut spawn, &descriptor, None)
                .expect("non-openrouter descriptors never need credentials");
            assert!(credential.is_none());
            assert_eq!(spawn.args, vec!["--acp"]);
        }
    }

    #[test]
    fn openrouter_credential_is_written_to_a_private_request_scoped_file() {
        let descriptor = descriptor(OPENROUTER_DESCRIPTOR_ID);
        let request = AcpAgentStartRequest::default();
        let session_config = AcpSessionRequestConfig::from_request(&request, &descriptor);
        let mut spawn = build_spawn_config(
            &descriptor,
            &session_config,
            Path::new("/tmp"),
            Some("sk-request-scoped"),
        )
        .expect("build spawn config");
        assert_eq!(spawn.args, vec!["--acp"]);

        let credential =
            prepare_spawn_credential(&mut spawn, &descriptor, Some("sk-request-scoped"))
                .expect("OpenRouter credential")
                .expect("credential guard");
        assert_eq!(spawn.args.first().map(String::as_str), Some("--acp"));
        assert_eq!(
            spawn.args.get(1).map(String::as_str),
            Some("--api-key-file")
        );

        let credential_path =
            std::path::PathBuf::from(spawn.args.get(2).expect("credential path argument"));
        assert_eq!(
            std::fs::read_to_string(&credential_path).expect("read credential"),
            "sk-request-scoped"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            assert_eq!(
                std::fs::metadata(&credential_path)
                    .expect("credential metadata")
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        let parent = credential_path
            .parent()
            .expect("credential parent")
            .to_path_buf();
        drop(credential);
        assert!(!credential_path.exists());
        assert!(!parent.exists());
    }

    #[test]
    fn openrouter_credential_is_rejected_for_other_descriptors() {
        let error = validate_descriptor_credential(&descriptor("claude"), Some("must-not-leak"))
            .expect_err("credential must be descriptor-scoped");
        assert_eq!(error.code(), "WORKFLOW_PARSE");
        assert!(!format!("{error:?}").contains("must-not-leak"));
    }
}
