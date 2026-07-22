use std::collections::HashMap;
use std::path::Path;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::SessionStartRequest;
use crate::daemon::service::start_session_direct_async;
use crate::session::types::SessionState;
use crate::task_board::{
    AgentMode, SpawnGateSwitches, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardItem,
    TaskBoardPolicyLimit, TaskBoardPolicyScope, TaskBoardReadOnlyRunContext,
    TaskBoardReadOnlyWorkflowLaunch, TaskBoardWorkflowKind, build_dispatch_plans_with_policy,
    resolve_task_board_reviewers,
};

use super::super::task_board_workflow_test_support::TestDatabase;
use super::fixture::{FROZEN_HEAD, Fixture, NOW, seed_settings};

pub(super) async fn seed_dispatched_initial_report(label: &str) -> Fixture {
    let test = TestDatabase::open().await;
    seed_settings(&test.db).await;
    configure_admission(&test.db).await;
    let item_id = format!("coordinator-{label}");
    let mut item = TaskBoardItem::new(
        item_id.clone(),
        format!("Read-only workflow {label}"),
        "Inspect the exact frozen revision".into(),
        NOW.into(),
    );
    item.agent_mode = AgentMode::Evaluate;
    item.workflow_kind = TaskBoardWorkflowKind::Review;
    test.db
        .create_task_board_item(item.clone())
        .await
        .expect("create dispatched report item");
    let plan = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    let intent_id = match test
        .db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("reserve dispatched report")
    {
        crate::daemon::db::ReservedTaskBoardDispatch::Preparing { intent_id, .. } => intent_id,
        other => panic!("unexpected dispatched report reservation: {other:?}"),
    };
    let preparation = test
        .db
        .claim_task_board_dispatch_preparation(&intent_id)
        .await
        .expect("claim dispatched report preparation")
        .expect("pending dispatched report preparation");
    let fixture_root = test.path.parent().expect("prepared report fixture root");
    let session =
        start_dispatch_session(&test.db, fixture_root, &preparation.preparation.session_id).await;
    let worktree = session.worktree_path.to_string_lossy().into_owned();
    let launch = launch(&test.db, &item_id, &session).await;
    let applied = test
        .db
        .complete_task_board_dispatch_preparation_with_workflow(
            &preparation,
            &session.branch_ref,
            &worktree,
            Some(launch),
            None,
        )
        .await
        .expect("complete dispatched report preparation");
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .clone()
        .expect("dispatched report execution id");
    let claim = test
        .db
        .claim_task_board_dispatch(&item_id)
        .await
        .expect("claim dispatched report")
        .expect("pending dispatched report");
    test.db
        .prepare_task_board_workflow_dispatch(&intent_id, &claim.claim_token)
        .await
        .expect("prepare dispatched report before worker start");
    Fixture {
        test,
        item_id,
        execution_id,
    }
}

async fn start_dispatch_session(
    db: &AsyncDaemonDb,
    fixture_root: &Path,
    session_id: &str,
) -> SessionState {
    let project = fixture_root.join("project");
    std::fs::create_dir_all(&project).expect("create dispatched report project");
    harness_testkit::init_git_repo_with_seed(&project);
    let xdg = fixture_root.join("xdg");
    let xdg_value = xdg.to_string_lossy().into_owned();
    let project_value = project.to_string_lossy().into_owned();
    let state = temp_env::async_with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg_value.as_str())),
            (
                "CLAUDE_SESSION_ID",
                Some("77d13b08-1651-541b-a3fc-26cab59e0aea"),
            ),
        ],
        start_session_direct_async(
            &SessionStartRequest {
                title: "Prepared read-only report".into(),
                context: "Durable prepared report restart fixture".into(),
                session_id: Some(session_id.into()),
                project_dir: project_value,
                policy_preset: None,
                base_ref: None,
            },
            db,
        ),
    )
    .await
    .expect("start canonical dispatched report session");
    assert_eq!(state.session_id, session_id);
    state
}

async fn configure_admission(db: &AsyncDaemonDb) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load initial report admission settings");
    settings.admission_policy.limits = vec![TaskBoardPolicyLimit::Concurrency {
        scope: TaskBoardPolicyScope::Global,
        limit: 1,
        reservation: 1,
    }];
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure initial report admission");
}

async fn launch(
    db: &AsyncDaemonDb,
    item_id: &str,
    session: &SessionState,
) -> TaskBoardReadOnlyWorkflowLaunch {
    let snapshot = db
        .task_board_item_snapshot(item_id)
        .await
        .expect("dispatched report source item");
    let settings = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("dispatched report settings");
    TaskBoardReadOnlyWorkflowLaunch {
        workflow_kind: TaskBoardWorkflowKind::Review,
        execution_repository: None,
        configuration_revision: u64::try_from(settings.row_revision).expect("settings revision"),
        policy_version: settings.settings.policy_version,
        resolved_reviewers: resolve_task_board_reviewers(
            &settings.settings.reviewers,
            TaskBoardWorkflowKind::Review,
            None,
        )
        .expect("dispatched report reviewers"),
        source_item_revision: snapshot.item_revision,
        prepared_item_revision: snapshot.item_revision,
        run_context: TaskBoardReadOnlyRunContext {
            schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: session.session_id.clone(),
            title: snapshot.item.title,
            body: snapshot.item.body,
            tags: snapshot.item.tags,
            worktree: session.worktree_path.to_string_lossy().into_owned(),
        },
        provider_revision: None,
        pull_request: None,
        exact_head_revision: FROZEN_HEAD.into(),
    }
}
