use super::*;

use std::time::Duration as StdDuration;

use tempfile::tempdir;

use crate::daemon::service::serve::reconciliation_test_gate;

/// Reconciliation walks every discovered project, and the manifest is the only
/// way the Monitor learns the daemon's port. Running it inside the awaited
/// startup path left a real 1200-project daemon listening but undiscoverable
/// for ~30s, long enough that the app gave up and restarted it mid-boot.
#[test]
fn manifest_is_published_without_waiting_for_background_reconciliation() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("daemon-startup-reconciliation"),
            || {
                let gate = reconciliation_test_gate::install();
                // The gate parks a thread. On a current-thread runtime that
                // thread is also the one polling this test's timeout, so a
                // regression would hang here instead of failing.
                let runtime = tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(2)
                    .enable_all()
                    .build()
                    .expect("runtime");
                runtime.block_on(async {
                    let serve_task = tokio::spawn(async {
                        serve(DaemonServeConfig {
                            host: "127.0.0.1".into(),
                            port: 0,
                            ..DaemonServeConfig::default()
                        })
                        .await
                    });

                    let published = tokio::time::timeout(StdDuration::from_secs(10), async {
                        loop {
                            if state::load_running_manifest().ok().flatten().is_some() {
                                break;
                            }
                            tokio::time::sleep(StdDuration::from_millis(25)).await;
                        }
                    })
                    .await;

                    // Release before asserting so a regression fails the
                    // assertion instead of hanging the still-gated daemon.
                    reconciliation_test_gate::release(&gate);
                    assert!(
                        published.is_ok(),
                        "daemon must publish its manifest while reconciliation is still gated"
                    );

                    // Deferring the work must not mean dropping it.
                    tokio::time::timeout(StdDuration::from_secs(10), async {
                        loop {
                            if recorded_events()
                                .iter()
                                .any(|event| event.contains("background reconciliation:"))
                            {
                                break;
                            }
                            tokio::time::sleep(StdDuration::from_millis(25)).await;
                        }
                    })
                    .await
                    .expect("reconciliation still runs once startup has published");

                    request_shutdown().expect("request shutdown");
                    serve_task
                        .await
                        .expect("join daemon serve task")
                        .expect("daemon serve result");
                });
                reconciliation_test_gate::clear();
            },
        );
    });
}

fn recorded_events() -> Vec<String> {
    let path = state::daemon_root().join("events.jsonl");
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::to_string)
        .collect()
}
