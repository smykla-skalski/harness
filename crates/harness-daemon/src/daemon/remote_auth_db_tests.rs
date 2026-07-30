use crate::daemon::db::DaemonDb;
use crate::daemon::remote::RemoteRole;
use crate::daemon::remote_identity::RemoteClientRegistration;

#[test]
fn revoked_execution_coordinator_token_cannot_be_reauthenticated() {
    let db = DaemonDb::open_in_memory().expect("daemon database");
    let registration = RemoteClientRegistration::new_for_tests(
        "executor-revoked",
        "Remote executor",
        "linux",
        RemoteRole::ExecutionCoordinator,
        &[],
        "executor-token-secret",
        "2026-07-19T12:00:00Z",
    )
    .expect("executor registration");
    db.register_remote_client(&registration)
        .expect("register executor");
    assert!(
        db.verify_remote_client_token("executor-revoked", "executor-token-secret")
            .expect("verify active executor")
            .is_some()
    );

    assert!(
        db.revoke_remote_client("executor-revoked", "2026-07-19T12:01:00Z")
            .expect("revoke executor")
    );
    assert!(
        db.verify_remote_client_token("executor-revoked", "executor-token-secret")
            .expect("verify revoked executor")
            .is_none()
    );
}
