use tempfile::tempdir;

use crate::load_signals_for;

use super::support::{build_project, sample_signal_with_idempotency, sample_state_for_runtime};

// `session_detail_with_db_refreshes_shared_runtime_signal_index` lives in
// `harness-daemon`'s own `daemon::db::tests::snapshot_integration` instead of
// here: it needs a real `DaemonDb`, and this crate dev-depending on
// `harness-daemon` for that would create a dev-dependency cycle (this crate
// is `harness-daemon`'s own ordinary dependency), which Cargo resolves by
// compiling this crate twice - once per side of the cycle - producing two
// distinct instances of its `SnapshotStorage` trait that `DaemonDb` only
// implements for one.
#[test]
fn load_signals_for_filters_shared_runtime_session_history() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = tmp.path().join("harness/projects/project-alpha");
            let shared_runtime_session = "codex-shared-session";
            let session_one = "0c3be78e-656d-52d3-b4c3-03ba64d373ac";
            let session_two = "17625cc4-8be6-5f38-b1d6-e2342db78d57";

            let alpha_state =
                sample_state_for_runtime(session_one, "codex", shared_runtime_session);
            let beta_state = sample_state_for_runtime(session_two, "codex", shared_runtime_session);

            let shared_signal_dir = context_root
                .join("agents")
                .join("signals")
                .join("codex")
                .join(shared_runtime_session);
            harness_agents::runtime::signal::write_signal_file(
                &shared_signal_dir,
                &sample_signal_with_idempotency(
                    "sig-alpha",
                    "signal for alpha",
                    Some("0c3be78e-656d-52d3-b4c3-03ba64d373ac:codex-worker:inject_context"),
                ),
            )
            .expect("write alpha signal");
            harness_agents::runtime::signal::write_signal_file(
                &shared_signal_dir,
                &sample_signal_with_idempotency(
                    "sig-beta",
                    "signal for beta",
                    Some("17625cc4-8be6-5f38-b1d6-e2342db78d57:codex-worker:inject_context"),
                ),
            )
            .expect("write beta signal");

            let project = build_project(context_root);

            let alpha_signals = load_signals_for(&project, &alpha_state).expect("alpha signals");
            let beta_signals = load_signals_for(&project, &beta_state).expect("beta signals");

            assert_eq!(alpha_signals.len(), 1);
            assert_eq!(alpha_signals[0].signal.signal_id, "sig-alpha");
            assert_eq!(beta_signals.len(), 1);
            assert_eq!(beta_signals[0].signal.signal_id, "sig-beta");
        },
    );
}
