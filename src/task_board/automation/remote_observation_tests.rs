use chrono::{DateTime, Utc};
use serde_json::json;

use super::{
    TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS, TASK_BOARD_REMOTE_PROTOCOL_VERSION,
    TaskBoardExecutionHostAdvertisement, TaskBoardExecutionHostConfig,
    TaskBoardPhaseCapabilityProfile, validate_execution_host_advertisement,
    validate_execution_host_observation,
};

const NOW: &str = "2026-07-19T12:00:00Z";

fn observed_host() -> TaskBoardExecutionHostAdvertisement {
    TaskBoardExecutionHostAdvertisement {
        host_id: "remote-a".into(),
        host_instance_id: "boot-20260719-a".into(),
        protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
        repositories: vec!["acme/tools".into(), "acme/widgets".into()],
        runtimes: vec!["claude".into(), "codex".into()],
        capabilities: vec![
            TaskBoardPhaseCapabilityProfile::ImplementationWrite,
            TaskBoardPhaseCapabilityProfile::ReviewReadOnly,
            TaskBoardPhaseCapabilityProfile::EvaluateReadOnly,
        ],
        capacity: 4,
        active_assignments: 1,
        heartbeat_at: NOW.into(),
    }
}

fn configured_host() -> TaskBoardExecutionHostConfig {
    TaskBoardExecutionHostConfig {
        host_id: "remote-a".into(),
        endpoint: "https://remote.example.test".into(),
        certificate_fingerprint: crate::task_board::remote_spki_pin::encode([0x11; 32]),
        credential_reference: "env://HARNESS_REMOTE_A_TOKEN".into(),
        enabled: true,
    }
}

#[test]
fn observed_advertisement_is_strict_and_contains_no_trust_anchors() {
    let json = serde_json::to_value(observed_host()).expect("serialize advertisement");
    assert!(json.get("endpoint").is_none());
    assert!(json.get("certificate_fingerprint").is_none());
    assert!(json.get("credential_reference").is_none());

    let mut injected = json;
    injected["endpoint"] = json!("https://attacker.example.test");
    serde_json::from_value::<TaskBoardExecutionHostAdvertisement>(injected)
        .expect_err("observed state cannot replace operator trust anchors");
}

#[test]
fn authenticated_observation_cannot_change_operator_identity_or_enablement() {
    validate_execution_host_observation(&configured_host(), &observed_host())
        .expect("matching enabled host");

    let mut mismatch = observed_host();
    mismatch.host_id = "remote-b".into();
    validate_execution_host_observation(&configured_host(), &mismatch)
        .expect_err("authenticated response cannot claim another configured identity");

    let mut disabled = configured_host();
    disabled.enabled = false;
    validate_execution_host_observation(&disabled, &observed_host())
        .expect_err("disabled trust entry cannot become enabled through advertisement");
}

#[test]
fn observed_advertisement_requires_canonical_identity_and_capacity() {
    validate_execution_host_advertisement(&observed_host()).expect("canonical advertisement");

    let mut wrong_instance = observed_host();
    wrong_instance.host_instance_id = "".into();
    validate_execution_host_advertisement(&wrong_instance).expect_err("instance identity");

    let mut wrong_protocol = observed_host();
    wrong_protocol.protocol_version += 1;
    validate_execution_host_advertisement(&wrong_protocol).expect_err("protocol mismatch");

    let mut zero_capacity = observed_host();
    zero_capacity.capacity = 0;
    validate_execution_host_advertisement(&zero_capacity).expect_err("zero capacity");

    let mut overcommitted = observed_host();
    overcommitted.active_assignments = overcommitted.capacity + 1;
    validate_execution_host_advertisement(&overcommitted).expect_err("over capacity");
}

#[test]
fn observed_collections_are_canonical_sorted_unique_and_remote_only() {
    let mut host = observed_host();
    host.repositories = vec!["ACME/Widgets".into()];
    validate_execution_host_advertisement(&host).expect_err("repository must be canonical");

    host = observed_host();
    host.repositories.reverse();
    validate_execution_host_advertisement(&host).expect_err("repository order is canonical");

    host = observed_host();
    host.runtimes = vec!["codex".into(), "codex".into()];
    validate_execution_host_advertisement(&host).expect_err("runtime duplicates");

    host = observed_host();
    host.capabilities = vec![TaskBoardPhaseCapabilityProfile::PlanningReadOnly];
    validate_execution_host_advertisement(&host)
        .expect_err("planning is controller-owned and cannot be advertised");

    host = observed_host();
    host.capabilities.swap(0, 2);
    validate_execution_host_advertisement(&host).expect_err("capability order is canonical");
}

#[test]
fn heartbeat_is_canonical_and_has_a_bounded_freshness_window() {
    let now = parse(NOW);
    let host = observed_host();
    assert!(host.heartbeat_is_fresh_at(now));

    let mut boundary = observed_host();
    boundary.heartbeat_at = (now
        - chrono::Duration::seconds(TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS))
    .to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true);
    assert!(boundary.heartbeat_is_fresh_at(now));

    let mut stale = boundary;
    stale.heartbeat_at = (now
        - chrono::Duration::seconds(TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS + 1))
    .to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true);
    assert!(!stale.heartbeat_is_fresh_at(now));

    let mut future = observed_host();
    future.heartbeat_at =
        (now + chrono::Duration::seconds(1)).to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true);
    assert!(!future.heartbeat_is_fresh_at(now));

    let mut noncanonical = observed_host();
    noncanonical.heartbeat_at = "2026-07-19T14:00:00+02:00".into();
    validate_execution_host_advertisement(&noncanonical).expect_err("canonical UTC heartbeat");
}

fn parse(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .expect("test timestamp")
        .into()
}
