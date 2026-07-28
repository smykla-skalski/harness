//! The supervisor's construction is independent of `std::process::Child`. It
//! works from an explicit `SupervisedProcess`, which is what a transport that
//! did not spawn the agent supplies.

use super::super::{AcpSessionSupervisor, SupervisedProcess, SupervisionConfig, WatchdogState};

#[tokio::test(start_paused = true)]
async fn a_supervisor_built_without_a_child_reports_its_process() {
    let supervisor = AcpSessionSupervisor::with_process(
        SupervisedProcess::new(4242, 4242),
        SupervisionConfig::default(),
    );

    assert_eq!(supervisor.pid(), 4242);
    assert_eq!(supervisor.pgid(), 4242);
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);
}

/// The whole watchdog machinery runs on a supervisor that no `Child` backs, so
/// a remote transport can reuse it unchanged.
#[tokio::test(start_paused = true)]
async fn a_childless_supervisor_still_drives_the_watchdog() {
    let supervisor = AcpSessionSupervisor::with_process(
        SupervisedProcess::new(4242, 4242),
        SupervisionConfig::default(),
    );

    {
        let _pending = supervisor.enter_pending_request();
        assert_eq!(supervisor.watchdog_state(), WatchdogState::Active);
        assert_eq!(supervisor.pending_request_count(), 1);
    }

    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);
    assert_eq!(supervisor.pending_request_count(), 0);
}

/// A remote process reports the zero sentinel: there is no local pid or process
/// group, and nothing must ever reap group zero.
#[tokio::test(start_paused = true)]
async fn a_remote_process_reports_the_zero_sentinel() {
    let supervisor = AcpSessionSupervisor::with_process(
        SupervisedProcess::remote(),
        SupervisionConfig::default(),
    );

    assert_eq!(supervisor.pid(), 0);
    assert_eq!(supervisor.pgid(), 0);
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);
}
