use super::{
    TaskBoardExecutionCredentialReference, TaskBoardExecutionHostConfig, TaskBoardExecutionPhase,
    TaskBoardLocalExecutionHostConfig, TaskBoardLocalExecutionRepositoryConfig,
    TaskBoardPhaseCapabilityProfile, TaskBoardRemoteAssignmentState, TaskBoardRemoteHostState,
    TaskBoardRepositoryAutomationConfig, remote_capability_for_phase,
    validate_execution_host_config, validate_execution_host_configs,
    validate_local_execution_host_config, validate_remote_execution_configuration,
    validate_repository_remote_execution_config,
};
use crate::task_board::TaskBoardOrchestratorWorkflow;

fn config(reference: &str) -> TaskBoardExecutionHostConfig {
    TaskBoardExecutionHostConfig {
        host_id: "remote-a".into(),
        endpoint: "https://remote.example.test:8443".into(),
        certificate_fingerprint: crate::task_board::remote_spki_pin::encode([0x11; 32]),
        credential_reference: reference.into(),
        enabled: true,
    }
}

#[test]
fn trust_config_accepts_only_canonical_https_origins_and_spki_pins() {
    validate_execution_host_config(&config("env://HARNESS_REMOTE_A_TOKEN"))
        .expect("canonical trust config");

    for endpoint in [
        "http://remote.example.test",
        "https://REMOTE.example.test",
        "https://remote.example.test/",
        "https://remote.example.test/api",
        "https://user@remote.example.test",
        "https://remote.example.test?token=value",
        "https://remote.example.test#fragment",
    ] {
        let mut invalid = config("env://HARNESS_REMOTE_A_TOKEN");
        invalid.endpoint = endpoint.into();
        validate_execution_host_config(&invalid)
            .expect_err("noncanonical or unsafe endpoint must fail closed");
    }

    let canonical = crate::task_board::remote_spki_pin::encode([0x22; 32]);
    for fingerprint in [
        "a".repeat(64),
        canonical.to_uppercase(),
        canonical.trim_end_matches('=').to_owned(),
        format!("{canonical} "),
        "sha256/AA==".to_owned(),
        "sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".to_owned(),
    ] {
        let mut invalid = config("env://HARNESS_REMOTE_A_TOKEN");
        invalid.certificate_fingerprint = fingerprint;
        validate_execution_host_config(&invalid)
            .expect_err("only canonical pairing SPKI pins are accepted");
    }
}

#[test]
fn trust_config_rejects_unknown_fields_instead_of_persisting_placeholders() {
    let value = serde_json::json!({
        "host_id": "remote-a",
        "endpoint": "https://remote.example.test",
        "certificate_fingerprint": crate::task_board::remote_spki_pin::encode([0x11; 32]),
        "credential_reference": "env://HARNESS_REMOTE_A_TOKEN",
        "enabled": true,
        "advertised_endpoint": "https://attacker.example.test"
    });
    serde_json::from_value::<TaskBoardExecutionHostConfig>(value)
        .expect_err("unknown trust fields must fail closed");
}

#[test]
fn repository_checkout_source_is_optional_absolute_and_canonical() {
    let mut repository = TaskBoardRepositoryAutomationConfig {
        repository: "acme/widgets".into(),
        enabled: true,
        workflows: vec![TaskBoardOrchestratorWorkflow::DefaultTask],
        preferred_host_id: Some("remote-a".into()),
        execution_checkout_path: None,
    };
    validate_repository_remote_execution_config(&repository).expect("optional checkout source");
    repository.execution_checkout_path = Some("/srv/harness/remotes/acme-widgets".into());
    validate_repository_remote_execution_config(&repository).expect("trusted absolute source");

    for path in [
        "",
        "relative/checkout",
        "/",
        "/srv/harness/../other",
        "/srv/harness/./widgets",
        "/srv/harness//widgets",
        "//srv/harness/widgets",
        "/srv/harness/widgets/",
        " /srv/harness/widgets",
    ] {
        repository.execution_checkout_path = Some(path.into());
        assert!(
            validate_repository_remote_execution_config(&repository).is_err(),
            "unsafe checkout source '{path}' must fail closed"
        );
    }

    repository.execution_checkout_path = None;
    repository.repository = "ACME/Widgets".into();
    validate_repository_remote_execution_config(&repository)
        .expect_err("repository slug must already be canonical");
}

#[test]
fn repository_routing_references_only_configured_trust_anchors() {
    let host = config("env://HARNESS_REMOTE_A_TOKEN");
    let repository = TaskBoardRepositoryAutomationConfig {
        repository: "acme/widgets".into(),
        enabled: true,
        workflows: vec![TaskBoardOrchestratorWorkflow::DefaultTask],
        preferred_host_id: Some("remote-a".into()),
        execution_checkout_path: Some("/srv/harness/remotes/acme-widgets".into()),
    };
    validate_remote_execution_configuration(
        std::slice::from_ref(&host),
        std::slice::from_ref(&repository),
    )
    .expect("preferred host is configured");

    let mut dangling = repository.clone();
    dangling.preferred_host_id = Some("remote-b".into());
    validate_remote_execution_configuration(&[host], &[dangling])
        .expect_err("dangling preferred host must fail closed");

    validate_remote_execution_configuration(&[], &[repository.clone(), repository])
        .expect_err("duplicate repository routing is ambiguous");
}

#[test]
fn local_executor_is_default_off_and_requires_complete_operator_config() {
    validate_local_execution_host_config(&TaskBoardLocalExecutionHostConfig::default())
        .expect("default-off executor");

    let valid = TaskBoardLocalExecutionHostConfig {
        enabled: true,
        host_id: "remote-a".into(),
        capacity: 2,
        repositories: vec![TaskBoardLocalExecutionRepositoryConfig {
            repository: "acme/widgets".into(),
            checkout_path: "/srv/harness/remotes/acme-widgets".into(),
        }],
        runtimes: vec!["codex".into()],
        capabilities: vec![TaskBoardPhaseCapabilityProfile::ImplementationWrite],
    };
    validate_local_execution_host_config(&valid).expect("complete executor config");

    let mut partial = valid.clone();
    partial.repositories.clear();
    validate_local_execution_host_config(&partial).expect_err("repository roots are required");

    partial = valid.clone();
    partial.capacity = 0;
    validate_local_execution_host_config(&partial).expect_err("positive capacity is required");

    partial = valid;
    partial.repositories[0].checkout_path = "../caller-worktree".into();
    validate_local_execution_host_config(&partial)
        .expect_err("caller-relative worktrees are never host identity");
}

#[test]
fn credential_references_match_the_supported_resolvers_exactly() {
    assert_eq!(
        TaskBoardExecutionCredentialReference::parse("env://HARNESS_REMOTE_A_TOKEN")
            .expect("environment reference"),
        TaskBoardExecutionCredentialReference::Environment {
            name: "HARNESS_REMOTE_A_TOKEN".into(),
        }
    );
    assert_eq!(
        TaskBoardExecutionCredentialReference::parse(
            "keychain://io.harness.remote-executor/remote-a"
        )
        .expect("Keychain reference"),
        TaskBoardExecutionCredentialReference::Keychain {
            service: "io.harness.remote-executor".into(),
            account: "remote-a".into(),
        }
    );

    for reference in [
        "raw-bearer-token",
        "op://vault/item/token",
        "secret://namespace/token",
        "env://1INVALID",
        "env://TOKEN/path",
        "env://TOKEN?query=value",
        "keychain://service",
        "keychain://service/account/extra",
        "keychain://service/account%2Fother",
    ] {
        TaskBoardExecutionCredentialReference::parse(reference)
            .expect_err("unsupported or noncanonical references must fail closed");
    }
}

#[test]
fn host_configs_require_canonical_unique_operator_identity() {
    let first = config("env://HARNESS_REMOTE_A_TOKEN");
    validate_execution_host_configs(std::slice::from_ref(&first)).expect("one host");

    for host_id in ["", " remote-a", "remote/a", "remote..a", "Remote-A"] {
        let mut invalid = first.clone();
        invalid.host_id = host_id.into();
        validate_execution_host_config(&invalid).expect_err("noncanonical host id");
    }

    let mut duplicate_id = first.clone();
    duplicate_id.endpoint = "https://other.example.test".into();
    validate_execution_host_configs(&[first.clone(), duplicate_id]).expect_err("duplicate host id");

    let mut duplicate_endpoint = first.clone();
    duplicate_endpoint.host_id = "remote-b".into();
    duplicate_endpoint.credential_reference = "env://HARNESS_REMOTE_B_TOKEN".into();
    validate_execution_host_configs(&[first, duplicate_endpoint])
        .expect_err("one endpoint cannot identify two configured hosts");
}

#[test]
fn only_worker_phases_map_to_remote_capabilities() {
    assert_eq!(
        remote_capability_for_phase(TaskBoardExecutionPhase::Implementation).expect("worker phase"),
        TaskBoardPhaseCapabilityProfile::ImplementationWrite
    );
    assert_eq!(
        remote_capability_for_phase(TaskBoardExecutionPhase::Review).expect("worker phase"),
        TaskBoardPhaseCapabilityProfile::ReviewReadOnly
    );
    assert_eq!(
        remote_capability_for_phase(TaskBoardExecutionPhase::Evaluate).expect("worker phase"),
        TaskBoardPhaseCapabilityProfile::EvaluateReadOnly
    );
    for phase in [
        TaskBoardExecutionPhase::Planning,
        TaskBoardExecutionPhase::AwaitingApproval,
        TaskBoardExecutionPhase::Publish,
        TaskBoardExecutionPhase::Cleanup,
        TaskBoardExecutionPhase::Terminal,
    ] {
        remote_capability_for_phase(phase).expect_err("controller-owned phase must stay local");
    }
}

#[test]
fn persisted_state_decoding_is_complete_and_exact() {
    for (label, state) in [
        ("offered", TaskBoardRemoteAssignmentState::Offered),
        ("claimed", TaskBoardRemoteAssignmentState::Claimed),
        ("started", TaskBoardRemoteAssignmentState::Started),
        ("running", TaskBoardRemoteAssignmentState::Running),
        ("completed", TaskBoardRemoteAssignmentState::Completed),
        ("failed", TaskBoardRemoteAssignmentState::Failed),
        ("cancelled", TaskBoardRemoteAssignmentState::Cancelled),
        ("unknown", TaskBoardRemoteAssignmentState::Unknown),
        ("superseded", TaskBoardRemoteAssignmentState::Superseded),
    ] {
        assert_eq!(
            TaskBoardRemoteAssignmentState::decode(label).unwrap(),
            state
        );
        assert_eq!(state.as_str(), label);
    }
    for invalid in ["Superseded", "superseded ", "rejected", ""] {
        TaskBoardRemoteAssignmentState::decode(invalid).expect_err("noncanonical state");
    }

    for (label, state) in [
        ("healthy", TaskBoardRemoteHostState::Healthy),
        ("degraded", TaskBoardRemoteHostState::Degraded),
        ("unavailable", TaskBoardRemoteHostState::Unavailable),
        ("disabled", TaskBoardRemoteHostState::Disabled),
    ] {
        assert_eq!(TaskBoardRemoteHostState::decode(label).unwrap(), state);
        assert_eq!(state.as_str(), label);
    }
}
