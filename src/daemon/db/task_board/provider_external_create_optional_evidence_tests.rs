use tempfile::tempdir;

use super::provider_external_creates_tests::{begin, connect, create_evidence, create_item, item};
use crate::task_board::ExternalProvider;

#[tokio::test]
async fn github_recovery_accepts_none_revision_and_project_evidence() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-create-github-optional")).await;
    let intent = begin(&db, "task-create-github-optional", ExternalProvider::GitHub).await;
    let (mut outcome, mut baseline) =
        create_evidence(&intent, "example/repository#81", "revision-1");
    outcome.provider_revision = None;
    outcome.provider_project_id = None;
    let state = baseline.sync_state.as_mut().expect("sync state");
    state.updated_at = None;
    state.project_id = None;

    let created = db
        .record_task_board_external_create_outcome(&intent, &outcome, &baseline)
        .await
        .expect("record optional GitHub evidence");
    let finalized = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize optional GitHub evidence");

    let evidence = created.created_evidence().expect("created evidence");
    assert_eq!(evidence.outcome.provider_revision, None);
    assert_eq!(evidence.outcome.provider_project_id, None);
    let linked = finalized.item.expect("linked item");
    assert_eq!(
        linked.execution_repository.as_deref(),
        Some("example/repository")
    );
    let state = linked.external_refs[0]
        .sync_state
        .as_ref()
        .expect("linked sync state");
    assert_eq!(state.updated_at, None);
    assert_eq!(state.project_id, None);
}

#[tokio::test]
async fn optional_project_and_revision_evidence_must_match_exactly() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-create-optional-mismatch")).await;
    let intent = begin(
        &db,
        "task-create-optional-mismatch",
        ExternalProvider::GitHub,
    )
    .await;
    let (outcome, baseline) = create_evidence(&intent, "example/repository#83", "revision-3");

    let mut cases = Vec::new();
    let mut missing_outcome_revision = outcome.clone();
    missing_outcome_revision.provider_revision = None;
    cases.push((
        "outcome-revision",
        missing_outcome_revision,
        baseline.clone(),
    ));
    let mut missing_baseline_revision = baseline.clone();
    missing_baseline_revision
        .sync_state
        .as_mut()
        .expect("sync state")
        .updated_at = None;
    cases.push((
        "baseline-revision",
        outcome.clone(),
        missing_baseline_revision,
    ));
    let mut missing_outcome_project = outcome.clone();
    missing_outcome_project.provider_project_id = None;
    cases.push(("outcome-project", missing_outcome_project, baseline.clone()));
    let mut missing_baseline_project = baseline.clone();
    missing_baseline_project
        .sync_state
        .as_mut()
        .expect("sync state")
        .project_id = None;
    cases.push((
        "baseline-project",
        outcome.clone(),
        missing_baseline_project,
    ));

    for (case, outcome, baseline) in cases {
        let error = db
            .record_task_board_external_create_outcome(&intent, &outcome, &baseline)
            .await
            .expect_err("mixed optional evidence must fail");
        assert_eq!(error.code(), "WORKFLOW_CONCURRENT", "case {case}");
    }
}

#[tokio::test]
async fn github_supplied_project_must_match_the_external_identity() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-create-github-project-mismatch")).await;
    let intent = begin(
        &db,
        "task-create-github-project-mismatch",
        ExternalProvider::GitHub,
    )
    .await;
    let (mut outcome, mut baseline) =
        create_evidence(&intent, "example/repository#84", "revision-4");
    outcome.provider_project_id = Some("other/repository".into());
    baseline.sync_state.as_mut().expect("sync state").project_id = Some("other/repository".into());

    let error = db
        .record_task_board_external_create_outcome(&intent, &outcome, &baseline)
        .await
        .expect_err("GitHub project must match external identity");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
}
