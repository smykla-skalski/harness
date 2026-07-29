use std::sync::{Mutex, PoisonError};

use super::*;
use crate::{
    TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION, TaskBoardDependencyApprovalEvidence,
    TaskBoardDependencyCheck, TaskBoardDependencyCheckState, TaskBoardDependencyConflictEvidence,
    TaskBoardDependencyConflictState, TaskBoardDependencyIdentity, TaskBoardDependencyTriageStep,
    TaskBoardDependencyUpdateClass, parse_task_board_dependency_triage_result,
};

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";

#[test]
fn compiler_binds_documented_actions_to_exact_head_capabilities() {
    let result = safe_result();
    let plan = compile_task_board_dependency_action_plan(&result).expect("valid plan");

    assert_eq!(plan.actions.len(), 2);
    assert_eq!(
        plan.actions[1].kind,
        TaskBoardDependencyActionKind::ContinueWorkflow
    );
    assert_eq!(plan.actions[1].exact_head_revision, HEAD);
    assert_eq!(
        plan.capabilities,
        BTreeSet::from([
            TaskBoardDependencyActionCapability::TaskBoardAudit,
            TaskBoardDependencyActionCapability::TaskBoardAdvance,
        ])
    );
}

#[test]
fn compiler_rejects_duplicate_capabilities_without_the_outer_validator() {
    let mut result = safe_result();
    result.required_tools.push("task_board.audit".into());

    assert_eq!(
        compile_task_board_dependency_action_plan(&result),
        Err(TaskBoardDependencyTriageError::InvalidRequiredTool)
    );
}

#[test]
fn compiler_rejects_order_and_reason_without_the_outer_validator() {
    let mut unordered = safe_result();
    unordered.next_steps[1].order = 1;
    assert_eq!(
        compile_task_board_dependency_action_plan(&unordered),
        Err(TaskBoardDependencyTriageError::ActionPlanContradictsDisposition)
    );

    let mut empty_reason = safe_result();
    empty_reason.next_steps[1].reason = "  ".into();
    assert_eq!(
        compile_task_board_dependency_action_plan(&empty_reason),
        Err(TaskBoardDependencyTriageError::ActionPlanContradictsDisposition)
    );
}

#[test]
fn model_supplied_action_arguments_are_rejected_by_the_wire_schema() {
    let mut payload = serde_json::to_value(safe_result()).expect("serialize result");
    payload["next_steps"][0]["command"] = serde_json::json!("rm -rf workspace");
    let report = serde_json::to_string(&payload).expect("serialize payload");

    assert!(matches!(
        parse_task_board_dependency_triage_result(&report, "acme/widgets", 17, HEAD),
        Err(TaskBoardDependencyTriageError::InvalidJson(_))
    ));
}

#[tokio::test]
async fn unknown_action_is_audited_before_any_capability_runs() {
    let mut result = safe_result();
    result.next_steps[1].action = "run_shell\nFORGED_AUDIT".into();
    let registry = Registry::all();
    let audit = Audit::default();

    assert!(
        execute(&result, &registry, &audit)
            .await
            .expect_err("unknown action")
            .to_string()
            .contains("unsupported action")
    );
    assert!(registry.executed().is_empty());
    let records = audit.records();
    assert_eq!(records.len(), 1);
    assert_eq!(
        records[0].decision,
        TaskBoardDependencyActionAuditDecision::Rejected
    );
    assert!(!records[0].reason.contains("FORGED_AUDIT"));
    assert_eq!(records[0].source_result, result);
}

#[tokio::test]
async fn unknown_tool_and_invalid_order_fail_before_any_capability_runs() {
    let registry = Registry::all();
    let audit = Audit::default();
    let mut unknown_tool = safe_result();
    unknown_tool.required_tools[1] = "shell.exec\nFORGED_AUDIT".into();
    assert!(
        execute(&unknown_tool, &registry, &audit)
            .await
            .expect_err("unknown tool")
            .to_string()
            .contains("invalid required tool")
    );
    assert!(!audit.records()[0].reason.contains("FORGED_AUDIT"));

    let mut unordered = safe_result();
    unordered.next_steps.swap(0, 1);
    execute(&unordered, &registry, &audit)
        .await
        .expect_err("invalid order");
    assert!(registry.executed().is_empty());
    assert_eq!(audit.records().len(), 2);
}

#[tokio::test]
async fn unavailable_capability_rejects_the_whole_plan_before_execution() {
    let result = safe_result();
    let registry = Registry::only(TaskBoardDependencyActionCapability::TaskBoardAudit);
    let audit = Audit::default();

    let error = execute(&result, &registry, &audit)
        .await
        .expect_err("missing capability");

    assert!(error.to_string().contains("task_board.advance"));
    assert!(registry.executed().is_empty());
    assert_eq!(audit.records()[0].action, "continue_workflow");
}

#[tokio::test]
async fn executor_records_admission_then_uses_typed_registered_capabilities() {
    let result = safe_result();
    let registry = Registry::all();
    let audit = Audit::default();

    execute(&result, &registry, &audit)
        .await
        .expect("execute plan");

    assert_eq!(
        registry.executed(),
        vec![
            (
                TaskBoardDependencyActionCapability::TaskBoardAudit,
                TaskBoardDependencyActionKind::RecordResult,
                HEAD.into(),
            ),
            (
                TaskBoardDependencyActionCapability::TaskBoardAdvance,
                TaskBoardDependencyActionKind::ContinueWorkflow,
                HEAD.into(),
            ),
        ]
    );
    assert!(
        audit
            .records()
            .iter()
            .all(|record| record.decision == TaskBoardDependencyActionAuditDecision::Accepted)
    );
}

#[tokio::test]
async fn stale_head_and_report_only_mutation_fail_before_execution() {
    let registry = Registry::all();
    let audit = Audit::default();
    let result = safe_result();
    execute_task_board_dependency_action_plan(
        &result,
        "acme/widgets",
        17,
        "abcdefabcdefabcdefabcdefabcdefabcdefabcd",
        &registry,
        &audit,
    )
    .await
    .expect_err("stale head");
    assert!(registry.executed().is_empty());

    let mut report = safe_result();
    report.disposition = TaskBoardDependencyTriageDisposition::ReportOnly;
    report.required_tools = vec!["task_board.audit".into(), "codex.dispatch".into()];
    report.next_steps[1].action = "complete_report".into();
    assert_eq!(
        compile_task_board_dependency_action_plan(&report),
        Err(TaskBoardDependencyTriageError::MutationForbidden)
    );
}

async fn execute(
    result: &TaskBoardDependencyTriageResult,
    registry: &Registry,
    audit: &Audit,
) -> Result<(), CliError> {
    execute_task_board_dependency_action_plan(result, "acme/widgets", 17, HEAD, registry, audit)
        .await
}

#[derive(Default)]
struct Audit {
    records: Mutex<Vec<TaskBoardDependencyActionAuditRecord>>,
}

impl Audit {
    fn records(&self) -> Vec<TaskBoardDependencyActionAuditRecord> {
        self.records
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

#[async_trait]
impl TaskBoardDependencyActionAuditSink for Audit {
    async fn record(&self, record: TaskBoardDependencyActionAuditRecord) -> Result<(), CliError> {
        self.records
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(record);
        Ok(())
    }
}

type Executed = (
    TaskBoardDependencyActionCapability,
    TaskBoardDependencyActionKind,
    String,
);

struct Registry {
    supported: BTreeSet<TaskBoardDependencyActionCapability>,
    executed: Mutex<Vec<Executed>>,
}

impl Registry {
    fn all() -> Self {
        Self::with_supported([
            TaskBoardDependencyActionCapability::TaskBoardAudit,
            TaskBoardDependencyActionCapability::GitHubRead,
            TaskBoardDependencyActionCapability::CodexDispatch,
            TaskBoardDependencyActionCapability::TaskBoardAdvance,
        ])
    }

    fn only(capability: TaskBoardDependencyActionCapability) -> Self {
        Self::with_supported([capability])
    }

    fn with_supported(
        supported: impl IntoIterator<Item = TaskBoardDependencyActionCapability>,
    ) -> Self {
        Self {
            supported: supported.into_iter().collect(),
            executed: Mutex::new(Vec::new()),
        }
    }

    fn executed(&self) -> Vec<Executed> {
        self.executed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

#[async_trait]
impl TaskBoardDependencyActionCapabilityRegistry for Registry {
    fn supports(&self, capability: TaskBoardDependencyActionCapability) -> bool {
        self.supported.contains(&capability)
    }

    async fn execute(
        &self,
        capability: TaskBoardDependencyActionCapability,
        action: &TaskBoardDependencyValidatedAction,
    ) -> Result<(), CliError> {
        self.executed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((capability, action.kind, action.exact_head_revision.clone()));
        Ok(())
    }
}

fn safe_result() -> TaskBoardDependencyTriageResult {
    TaskBoardDependencyTriageResult {
        schema_version: TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION,
        repository: "acme/widgets".into(),
        pull_request_number: 17,
        exact_head_revision: HEAD.into(),
        dependency: TaskBoardDependencyIdentity {
            name: "serde".into(),
            ecosystem: "cargo".into(),
            current_version: "1.0.200".into(),
            target_version: "1.0.201".into(),
            update_class: TaskBoardDependencyUpdateClass::Patch,
        },
        checks: vec![TaskBoardDependencyCheck {
            name: "test".into(),
            state: TaskBoardDependencyCheckState::Passed,
            details_url: None,
        }],
        conflicts: TaskBoardDependencyConflictEvidence {
            state: TaskBoardDependencyConflictState::Clean,
            summary: "clean".into(),
        },
        approvals: TaskBoardDependencyApprovalEvidence {
            current: 1,
            required: 1,
        },
        safety_assumption: "green patch update".into(),
        disposition: TaskBoardDependencyTriageDisposition::ContinueSafe,
        required_tools: vec!["task_board.audit".into(), "task_board.advance".into()],
        next_steps: vec![
            TaskBoardDependencyTriageStep {
                order: 1,
                action: "record_result".into(),
                reason: "retain decision".into(),
            },
            TaskBoardDependencyTriageStep {
                order: 2,
                action: "continue_workflow".into(),
                reason: "advance safe result".into(),
            },
        ],
    }
}
