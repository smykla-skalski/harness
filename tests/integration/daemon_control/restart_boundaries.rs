//! Cross real daemon restart boundaries for board-driven pull-request work.
//!
//! The closed #880 driver reopened a database connection per tick inside one
//! process against one fake runtime, and its fixtures began after admission,
//! so a green run never proved recovery at the boundaries #1003 names. The
//! driver here (in `driver`) supersedes it: it enters through the daemon's
//! public task-board HTTP surface, starts from a Todo ticket rather than a
//! prebuilt running execution, and each restart replaces the real
//! `harness-daemon` process (and the runtime state it reopens) exactly as
//! `daemon_restart_replaces_running_manual_daemon` does. Outcomes stay
//! deterministic because nothing live is attached: no provider credential,
//! bridge, check, or GitHub call is made, so the agent, check, and GitHub
//! results are whatever the daemon computes with nothing attached, which is
//! stable across runs. An optional live adapter swaps in through
//! `WorkflowRuntime` without changing the driver.
//!
//! Every failure report carries the stage plus a correlation id - the ticket
//! being driven, or the daemon instance for a restart - so a green run and a
//! failing run point at the same execution.
//!
//! Production mid-launch restart recovery stays in #919; these tests exercise
//! the recovery that already exists at the admission boundary of umbrella #997.

mod driver;

use driver::{FakeRuntime, RestartDriver, RestartFailure, Stage};

use super::*;

fn workflow_status(item: &Value) -> String {
    item["workflow"]["status"]
        .as_str()
        .unwrap_or("idle")
        .to_owned()
}

fn assert_not_blocked_on_approval(plan: &Value) {
    let readiness = &plan["readiness"];
    if readiness["state"] == json!("blocked") {
        assert_ne!(
            readiness["reason"]["kind"],
            json!("plan_approval"),
            "an imported pull request must never be stranded on plan approval: {plan}"
        );
    }
}

trait UnwrapOrReport<T> {
    fn or_report(self) -> T;
}

impl<T> UnwrapOrReport<T> for Result<T, RestartFailure> {
    fn or_report(self) -> T {
        self.unwrap_or_else(|failure| panic!("{}", failure.describe()))
    }
}

#[test]
fn an_admitted_review_resumes_exactly_once_across_a_real_daemon_restart() {
    let tmp = tempdir().expect("tempdir");
    let mut driver = RestartDriver::start(tmp.path(), Box::new(FakeRuntime));

    driver
        .import_todo_seed("restart-review", "pr_review")
        .or_report();
    let admitted = driver.admit_to_todo("restart-review").or_report();
    assert_eq!(admitted["agent_mode"], json!("evaluate"), "{admitted}");

    let plan = driver.dispatch_plan("restart-review").or_report();
    assert_not_blocked_on_approval(&plan);
    let before = driver.get_item("restart-review").or_report();
    assert_eq!(workflow_status(&before), "idle", "{before}");
    assert!(before["workflow"]["execution_id"].is_null(), "{before}");

    driver.restart("restart-review").or_report();

    // The board entry survived the real process, bootstrap, and db-reopen
    // boundary rather than being rebuilt or lost.
    let recovered = driver.get_item("restart-review").or_report();
    assert_eq!(recovered["status"], json!("todo"), "{recovered}");
    assert_eq!(recovered["agent_mode"], json!("evaluate"), "{recovered}");
    assert_eq!(
        workflow_status(&recovered),
        "idle",
        "the process replacement must not stamp a phantom execution: {recovered}"
    );
    assert!(
        recovered["workflow"]["execution_id"].is_null(),
        "the process replacement must not stamp a phantom execution: {recovered}"
    );

    // Resuming plans exactly one eligible step (dispatch_plan asserts the count)
    // and stamps no execution, so the restart neither advanced nor duplicated
    // the pipeline.
    let replan = driver.dispatch_plan("restart-review").or_report();
    assert_not_blocked_on_approval(&replan);
    let after = driver.get_item("restart-review").or_report();
    assert_eq!(workflow_status(&after), "idle", "{after}");
    assert!(
        after["workflow"]["execution_id"].is_null(),
        "resuming must leave exactly one eligible step, not a second execution: {after}"
    );

    driver.stop();
}

#[test]
fn a_failed_admission_stays_cleared_across_a_real_daemon_restart() {
    let tmp = tempdir().expect("tempdir");
    // A directory that exists but is not a git repository: the reservation
    // succeeds and stamps an Admitting execution, then preparation fails when it
    // tries to cut a worktree, so the ticket must roll back cleanly.
    let project = tmp.path().join("not-a-git-project");
    std::fs::create_dir_all(&project).expect("create project");
    let mut driver = RestartDriver::start(tmp.path(), Box::new(FakeRuntime));

    driver.import_todo_seed("restart-dep", "pr_fix").or_report();
    driver.admit_to_todo("restart-dep").or_report();
    driver.open_spawn_gate();

    let response = driver.dispatch_real("restart-dep", &project).or_report();
    let failures = response["failures"].as_array().expect("failures array");
    assert_eq!(
        failures.len(),
        1,
        "an unusable project must fail admission: {response}"
    );
    // The daemon's own failure payload names the ticket, and the report surfaces
    // that identity rather than a literal supplied by the test.
    let failed_id = failures[0]["board_item_id"]
        .as_str()
        .expect("failure names its board item");
    assert_eq!(failed_id, "restart-dep", "{response}");
    let report = RestartFailure::new(
        Stage::Recover,
        failed_id,
        failures[0]["message"]
            .as_str()
            .unwrap_or("preparation failed"),
    );
    assert!(
        report.describe().contains("correlation_id=restart-dep"),
        "{}",
        report.describe()
    );

    let cleared = driver.get_item("restart-dep").or_report();
    assert_ne!(
        cleared["workflow"]["status"],
        json!("admitting"),
        "{cleared}"
    );
    assert!(cleared["workflow"]["execution_id"].is_null(), "{cleared}");

    driver.restart("restart-dep").or_report();

    // The cleanup is durable across the real restart: the ticket is not
    // resurrected into Admitting and its dead execution stays gone.
    let recovered = driver.get_item("restart-dep").or_report();
    assert_ne!(
        recovered["workflow"]["status"],
        json!("admitting"),
        "{recovered}"
    );
    assert!(
        recovered["workflow"]["execution_id"].is_null(),
        "the dead execution must not survive the restart: {recovered}"
    );

    // Recovery leaves the ticket cleanly retryable exactly once, not stranded
    // and not carrying a duplicate of the pre-restart attempt.
    let replan = driver.dispatch_plan("restart-dep").or_report();
    assert_eq!(replan["board_item_id"], json!("restart-dep"), "{replan}");

    driver.stop();
}

#[test]
fn restart_failure_describes_stage_and_correlation() {
    let failure = RestartFailure::new(Stage::Restart, "ticket-42", "pid stayed 100");
    let described = failure.describe();
    assert!(described.contains("stage=daemon_restart"), "{described}");
    assert!(
        described.contains("correlation_id=ticket-42"),
        "{described}"
    );
    assert!(described.contains("pid stayed 100"), "{described}");
}
