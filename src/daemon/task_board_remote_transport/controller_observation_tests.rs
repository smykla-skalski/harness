use std::collections::BTreeSet;
use std::sync::Arc;

use chrono::{Duration, SecondsFormat, Utc};
use sqlx::query_scalar;

use super::controller::RemoteExecutionControllerClient;
use super::controller_authority_test_support::{
    BarrierServer, HOST_ID, TOKEN_ENV, TestTlsMaterial, pinned_controller_for_trust_with_times,
    remote_host_config, spawn_barrier_server, spawn_probe_server, test_tls_material,
};
use super::wire::{RemoteHostAdvertisement, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION};
use crate::daemon::db::{AsyncDaemonDb, remote_controller_fixture};
use crate::task_board::{
    TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS, TASK_BOARD_REMOTE_PROTOCOL_VERSION,
    TaskBoardExecutionHostConfig,
};

const ROTATED_TOKEN_ENV: &str = "HARNESS_REMOTE_AUTHORITY_ROTATED_TOKEN";

#[tokio::test]
async fn advertisement_receipt_time_is_captured_after_the_network_response() {
    let fixture = remote_controller_fixture(1).await;
    let sent = Utc::now();
    let received = sent + Duration::seconds(5);
    let advertisement = RemoteHostAdvertisement {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        host_id: "executor-a".into(),
        host_instance_id: "instance-a".into(),
        protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
        capabilities: BTreeSet::from(["review_read_only".into()]),
        runtimes: BTreeSet::from(["codex".into()]),
        repositories: BTreeSet::from(["example/harness".into()]),
        capacity: 1,
        active_assignments: 0,
        sent_at: canonical_time(sent),
    };
    let tls = test_tls_material();
    let BarrierServer {
        endpoint,
        seen,
        release,
        requests,
    } = spawn_barrier_server(
        &tls,
        serde_json::to_string(&advertisement).expect("advertisement JSON"),
    )
    .await;
    let config = remote_host_config(&endpoint, &tls, &format!("env://{TOKEN_ENV}"), true);
    replace_remote_host(&fixture.db, config.clone()).await;
    assert_eq!(observation_count(&fixture.db).await, 0);
    let trust = fixture
        .db
        .task_board_remote_host_trust_fence(HOST_ID)
        .await
        .expect("load first-advertisement trust");
    let controller =
        pinned_controller_for_trust_with_times(trust, &tls, [canonical_time(received)]);

    let selection = temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let call = tokio::spawn(async move { controller.refresh_observation(&fixture.db).await });
        seen.await.expect("advertisement request reached executor");
        release.send(()).expect("release delayed advertisement");
        call.await
            .expect("advertisement controller task")
            .expect("record delayed advertisement")
    })
    .await;
    assert_eq!(requests.await.expect("advertisement server"), 1);
    assert_eq!(selection.received_at, canonical_time(received));
    assert_eq!(selection.advertisement.heartbeat_at, canonical_time(sent));
    assert!(selection.advertisement.heartbeat_is_fresh_at(received));
    assert!(!selection.advertisement.heartbeat_is_fresh_at(
        sent + Duration::seconds(TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS + 1)
    ));
}

#[tokio::test]
async fn advertisement_response_cannot_cross_a_trust_rotation() {
    let fixture = remote_controller_fixture(1).await;
    let sent = Utc::now();
    let old_tls = test_tls_material();
    let old_server = spawn_barrier_server(
        &old_tls,
        serde_json::to_string(&advertisement(sent)).expect("old advertisement JSON"),
    )
    .await;
    let old_config = remote_host_config(
        &old_server.endpoint,
        &old_tls,
        &format!("env://{TOKEN_ENV}"),
        true,
    );
    let old_revision = replace_remote_host(&fixture.db, old_config.clone()).await;
    let old_trust = fixture
        .db
        .task_board_remote_host_trust_fence(HOST_ID)
        .await
        .expect("load old advertisement trust");
    let old_controller = Arc::new(pinned_controller_for_trust_with_times(
        old_trust,
        &old_tls,
        [canonical_time(sent + Duration::seconds(5))],
    ));

    let new_tls = test_tls_material();
    let new_server = spawn_barrier_server(
        &new_tls,
        serde_json::to_string(&advertisement(sent + Duration::seconds(6)))
            .expect("new advertisement JSON"),
    )
    .await;
    let new_config = remote_host_config(
        &new_server.endpoint,
        &new_tls,
        &format!("env://{ROTATED_TOKEN_ENV}"),
        true,
    );
    assert_ne!(new_config.endpoint, old_config.endpoint);
    assert_ne!(
        new_config.certificate_fingerprint,
        old_config.certificate_fingerprint
    );
    assert_ne!(
        new_config.credential_reference,
        old_config.credential_reference
    );
    temp_env::async_with_vars(
        [
            (TOKEN_ENV, Some("authority-secret")),
            (ROTATED_TOKEN_ENV, Some("rotated-secret")),
        ],
        execute_trust_rotation_barrier(
            fixture.db,
            old_controller,
            old_server,
            new_server,
            new_tls,
            new_config,
            old_revision,
        ),
    )
    .await;
}

async fn execute_trust_rotation_barrier(
    db: AsyncDaemonDb,
    old_controller: Arc<RemoteExecutionControllerClient>,
    old_server: BarrierServer,
    new_server: BarrierServer,
    new_tls: TestTlsMaterial,
    new_config: TaskBoardExecutionHostConfig,
    old_revision: u64,
) {
    let pending_controller = Arc::clone(&old_controller);
    let pending_db = db.clone();
    let pending =
        tokio::spawn(async move { pending_controller.refresh_observation(&pending_db).await });
    old_server
        .seen
        .await
        .expect("old advertisement reached executor");
    let new_revision = replace_remote_host(&db, new_config.clone()).await;
    assert_ne!(new_revision, old_revision);
    assert_eq!(observation_count(&db).await, 0);
    let fresh_trust = db
        .task_board_remote_host_trust_fence(HOST_ID)
        .await
        .expect("load fresh advertisement trust");
    let fresh_controller = pinned_controller_for_trust_with_times(
        fresh_trust,
        &new_tls,
        [canonical_time(Utc::now() + Duration::seconds(10))],
    );
    old_server
        .release
        .send(())
        .expect("release old advertisement");
    let error = pending
        .await
        .expect("old controller task")
        .expect_err("rotated trust must reject old response");
    assert!(error.to_string().contains("trust configuration changed"));
    assert_eq!(observation_count(&db).await, 0);

    let stale = old_controller
        .refresh_observation(&db)
        .await
        .expect_err("old client must fail before another request");
    assert!(
        stale
            .to_string()
            .contains("client trust configuration is stale")
    );
    assert_eq!(old_server.requests.await.expect("old server requests"), 1);

    let fresh_db = db.clone();
    let fresh = tokio::spawn(async move { fresh_controller.refresh_observation(&fresh_db).await });
    new_server
        .seen
        .await
        .expect("new advertisement reached executor");
    new_server
        .release
        .send(())
        .expect("release new advertisement");
    let selection = fresh
        .await
        .expect("fresh controller task")
        .expect("fresh trust records observation");
    assert_eq!(selection.configuration_revision, new_revision);
    assert_eq!(selection.config, new_config);
    assert_eq!(new_server.requests.await.expect("new server requests"), 1);
}

#[tokio::test]
async fn disabled_host_rejects_advertisement_before_io() {
    let fixture = remote_controller_fixture(1).await;
    let tls = test_tls_material();
    let (endpoint, requests) = spawn_probe_server(&tls).await;
    let config = remote_host_config(&endpoint, &tls, &format!("env://{TOKEN_ENV}"), false);
    replace_remote_host(&fixture.db, config.clone()).await;
    let trust = fixture
        .db
        .task_board_remote_host_trust_fence(HOST_ID)
        .await
        .expect("load disabled advertisement trust");
    let controller = pinned_controller_for_trust_with_times(trust, &tls, []);

    let error = controller
        .refresh_observation(&fixture.db)
        .await
        .expect_err("disabled host must fail before advertise I/O");
    assert!(
        error
            .to_string()
            .contains("remote execution host is disabled")
    );
    assert_eq!(requests.await.expect("disabled probe requests"), 0);
}

fn advertisement(sent_at: chrono::DateTime<Utc>) -> RemoteHostAdvertisement {
    RemoteHostAdvertisement {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        host_id: "executor-a".into(),
        host_instance_id: "instance-a".into(),
        protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
        capabilities: BTreeSet::from(["review_read_only".into()]),
        runtimes: BTreeSet::from(["codex".into()]),
        repositories: BTreeSet::from(["example/harness".into()]),
        capacity: 1,
        active_assignments: 0,
        sent_at: canonical_time(sent_at),
    }
}

async fn replace_remote_host(db: &AsyncDaemonDb, config: TaskBoardExecutionHostConfig) -> u64 {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load remote host settings");
    settings.execution_hosts = vec![config];
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("replace remote host trust");
    db.task_board_remote_host_trust_fence("executor-a")
        .await
        .expect("load remote host trust fence")
        .configuration_revision
}

async fn observation_count(db: &AsyncDaemonDb) -> i64 {
    query_scalar(
        "SELECT COUNT(*) FROM task_board_execution_hosts
         WHERE host_id = 'executor-a' AND (
           observed_host_instance_id IS NOT NULL OR observed_protocol_version IS NOT NULL
           OR observed_capabilities_json IS NOT NULL OR observed_repositories_json IS NOT NULL
           OR observed_runtimes_json IS NOT NULL OR observed_capacity IS NOT NULL
           OR observed_active_assignments IS NOT NULL OR observed_state IS NOT NULL
           OR observed_received_at IS NOT NULL OR observed_heartbeat_at IS NOT NULL
           OR advertisement_sha256 IS NOT NULL
         )",
    )
    .fetch_one(db.pool())
    .await
    .expect("load remote observations")
}

fn canonical_time(time: chrono::DateTime<Utc>) -> String {
    time.to_rfc3339_opts(SecondsFormat::Secs, true)
}
