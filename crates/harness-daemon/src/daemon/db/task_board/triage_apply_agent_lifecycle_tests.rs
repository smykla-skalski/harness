//! Post-verdict lifecycle regression tests for the "agent verdicts do not
//! survive the next ingress touch" bug: `triage_cause` used to see a bare
//! identity mismatch between an `AGENT_V1` decision and whichever evaluator
//! is active, re-deciding on every later touch and demoting the agent's
//! placement. Split into its own file purely to keep
//! `triage_apply_agent_tests.rs` under the repo's line cap.

use super::{connect, decision_generation_count, lane_producer, seed_running_escalation};
use crate::task_board::{
    AGENT_V1_EVALUATOR_IDENTITY, TRIAGE_RULE_SET_SCHEMA_VERSION, TaskBoardPriority,
    TaskBoardStatus, TriagePriorityAction, TriageRule, TriageRuleCondition, TriageRuleOutcome,
    TriageRuleSetV1, TriageVerdict,
};

async fn pending_escalation_count(db: &crate::daemon::db::AsyncDaemonDb, item_id: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_triage_escalations
         WHERE item_id = ?1 AND status = 'pending'",
    )
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("count pending escalations")
}

fn bug_rule_set() -> TriageRuleSetV1 {
    TriageRuleSetV1 {
        schema_version: TRIAGE_RULE_SET_SCHEMA_VERSION,
        rules: vec![TriageRule {
            id: "bug".into(),
            when: vec![TriageRuleCondition::LabelsHasAny {
                labels: vec!["kind/bug".into()],
            }],
            outcome: TriageRuleOutcome {
                verdict: TriageVerdict::Todo,
                priority_action: TriagePriorityAction::SetTo {
                    priority: TaskBoardPriority::Critical,
                },
            },
        }],
        default_outcome: TriageRuleOutcome {
            verdict: TriageVerdict::Undecided,
            priority_action: TriagePriorityAction::Keep,
        },
    }
}

/// (a) The blocking bug's own 4-step repro: `triage_cause` used to see a
/// bare identity mismatch between an `AGENT_V1` decision and `BuiltInV1`
/// (the active evaluator) on every later touch, re-deciding Undecided,
/// demoting the agent-placed Todo back to Inbox, and re-enqueuing a fresh
/// (paid) escalation for evidence that never actually changed.
#[tokio::test]
async fn an_agent_todo_verdict_survives_an_unrelated_touch() {
    let (_directory, db) = connect().await;
    let (escalation_id, token, fingerprint) = seed_running_escalation(&db, "item-1").await;
    db.report_task_board_triage_escalation_verdict(
        &escalation_id,
        &token,
        &fingerprint,
        TriageVerdict::Todo,
        "clear enough once you read the body",
    )
    .await
    .expect("report verdict");
    let generations_before = decision_generation_count(&db, "item-1").await;

    db.update_task_board_item_with_triage("item-1", |item| {
        item.estimated_tokens = Some(500);
        Ok(true)
    })
    .await
    .expect("unrelated touch");

    let item = db.task_board_item("item-1").await.expect("load item");
    assert_eq!(
        item.status,
        TaskBoardStatus::Todo,
        "the agent verdict must survive an unrelated touch"
    );
    assert_eq!(
        decision_generation_count(&db, "item-1").await,
        generations_before,
        "an unrelated touch must not record a new decision generation"
    );
    assert_eq!(
        lane_producer(&db, "item-1").await.as_deref(),
        Some(AGENT_V1_EVALUATOR_IDENTITY),
        "placement must still be attributed to the agent evaluator"
    );
    assert_eq!(
        pending_escalation_count(&db, "item-1").await,
        0,
        "unchanged evidence must never re-enqueue a fresh escalation"
    );
}

/// (b) The Undecided leg of the same fix: an agent's Undecided verdict must
/// also survive an unrelated touch without re-enqueuing.
#[tokio::test]
async fn an_agent_undecided_verdict_survives_an_unrelated_touch_without_reenqueuing() {
    let (_directory, db) = connect().await;
    let (escalation_id, token, fingerprint) = seed_running_escalation(&db, "item-1").await;
    db.report_task_board_triage_escalation_verdict(
        &escalation_id,
        &token,
        &fingerprint,
        TriageVerdict::Undecided,
        "still nothing to go on",
    )
    .await
    .expect("report verdict");
    let generations_before = decision_generation_count(&db, "item-1").await;

    db.update_task_board_item_with_triage("item-1", |item| {
        item.estimated_tokens = Some(500);
        Ok(true)
    })
    .await
    .expect("unrelated touch");

    assert_eq!(
        decision_generation_count(&db, "item-1").await,
        generations_before,
        "an unrelated touch must not record a new decision generation"
    );
    assert_eq!(
        pending_escalation_count(&db, "item-1").await,
        0,
        "an unrelated touch must not re-enqueue while the agent's Undecided verdict still stands"
    );
}

/// (c) A genuine evidence change after an agent verdict is the one case
/// that must still re-decide: `FingerprintChanged` fires, the active
/// evaluator re-decides for real, and -- since the fresh decision is no
/// longer `AGENT_V1` -- a new escalation is enqueued if it comes back
/// Undecided.
#[tokio::test]
async fn a_genuine_evidence_change_after_an_agent_verdict_redecides_and_reenqueues() {
    let (_directory, db) = connect().await;
    let (escalation_id, token, fingerprint) = seed_running_escalation(&db, "item-1").await;
    db.report_task_board_triage_escalation_verdict(
        &escalation_id,
        &token,
        &fingerprint,
        TriageVerdict::Todo,
        "clear enough once you read the body",
    )
    .await
    .expect("report verdict");
    let generations_before = decision_generation_count(&db, "item-1").await;

    db.update_task_board_item_with_triage("item-1", |item| {
        item.title = "A completely different vague title".into();
        Ok(true)
    })
    .await
    .expect("genuine evidence change");

    assert_eq!(
        decision_generation_count(&db, "item-1").await,
        generations_before + 1,
        "a genuine evidence change must record a fresh decision generation"
    );
    let item = db.task_board_item("item-1").await.expect("load item");
    assert_eq!(
        item.status,
        TaskBoardStatus::Inbox,
        "the active evaluator's fresh Undecided verdict must land"
    );
    assert_eq!(
        pending_escalation_count(&db, "item-1").await,
        1,
        "the fresh Undecided decision (no longer AGENT_V1) must enqueue a new escalation"
    );
}

/// (d) An explicit design choice: activating a rule set must not disturb an
/// item an agent already decided with unchanged evidence, even though bulk
/// reevaluation would otherwise recompute a candidate verdict for every
/// eligible item.
#[tokio::test]
async fn rule_set_activation_leaves_a_current_agent_decision_untouched() {
    let (_directory, db) = connect().await;
    let (escalation_id, token, fingerprint) = seed_running_escalation(&db, "item-1").await;
    db.report_task_board_triage_escalation_verdict(
        &escalation_id,
        &token,
        &fingerprint,
        TriageVerdict::Todo,
        "clear enough once you read the body",
    )
    .await
    .expect("report verdict");
    let generations_before = decision_generation_count(&db, "item-1").await;

    db.activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("activate a rule set");

    assert_eq!(
        decision_generation_count(&db, "item-1").await,
        generations_before,
        "rule-set activation must not record a new decision for a current agent verdict"
    );
    let item = db.task_board_item("item-1").await.expect("load item");
    assert_eq!(
        item.status,
        TaskBoardStatus::Todo,
        "the agent's Todo verdict must survive the activation"
    );
    assert_eq!(
        lane_producer(&db, "item-1").await.as_deref(),
        Some(AGENT_V1_EVALUATOR_IDENTITY),
        "placement must stay attributed to the agent evaluator, not the newly active rule set"
    );
}

/// (e) Two consecutive unrelated touches after an agent Todo must apply
/// placement at most once (at verdict time) -- neither touch may reapply it
/// again, which would otherwise show up as repeated lane-transition churn
/// with no decision behind it.
#[tokio::test]
async fn two_consecutive_touches_after_an_agent_todo_cause_no_placement_reapply_churn() {
    let (_directory, db) = connect().await;
    let (escalation_id, token, fingerprint) = seed_running_escalation(&db, "item-1").await;
    db.report_task_board_triage_escalation_verdict(
        &escalation_id,
        &token,
        &fingerprint,
        TriageVerdict::Todo,
        "clear enough once you read the body",
    )
    .await
    .expect("report verdict");
    // `apply_placement_effect_in_tx` stamps `lane_set_at` to `decided_at`
    // every time it actually runs -- if no touch below reapplies placement,
    // this stays exactly what the verdict itself set.
    let lane_set_at_after_verdict = db
        .task_board_item("item-1")
        .await
        .expect("load item")
        .lane_set_at;

    for tokens in [500u64, 600u64] {
        db.update_task_board_item_with_triage("item-1", move |item| {
            item.estimated_tokens = Some(tokens);
            Ok(true)
        })
        .await
        .expect("unrelated touch");
    }

    let item = db.task_board_item("item-1").await.expect("load item");
    assert_eq!(
        item.lane_set_at, lane_set_at_after_verdict,
        "no touch after the agent verdict may reapply placement"
    );
    assert_eq!(
        lane_producer(&db, "item-1").await.as_deref(),
        Some(AGENT_V1_EVALUATOR_IDENTITY)
    );
}
