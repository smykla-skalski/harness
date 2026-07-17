use std::str::FromStr;

use clap::Args;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::types::{
    ExternalRef, ExternalRefProvider, PlanningState, TaskBoardWorkflowState,
    TaskBoardWorkflowStatus,
};
use crate::workspace::utc_now;

#[derive(Debug, Clone, Args)]
pub struct TaskBoardItemFieldArgs {
    #[arg(long)]
    pub external_ref: Vec<ExternalRefArg>,
    #[arg(long)]
    pub planning_summary: Option<String>,
    #[arg(long)]
    pub approved_by: Option<String>,
    #[arg(long)]
    pub approved_at: Option<String>,
    #[arg(long)]
    pub workflow_execution_id: Option<String>,
    #[arg(long, value_enum)]
    pub workflow_status: Option<TaskBoardWorkflowStatus>,
    #[arg(long)]
    pub workflow_current_step_id: Option<String>,
    #[arg(long)]
    pub workflow_attempts: Option<u32>,
    #[arg(long)]
    pub workflow_branch: Option<String>,
    #[arg(long)]
    pub workflow_worktree: Option<String>,
    #[arg(long)]
    pub workflow_pr_number: Option<u64>,
    #[arg(long)]
    pub workflow_pr_url: Option<String>,
    #[arg(long)]
    pub workflow_last_error: Option<String>,
    #[arg(long)]
    pub workflow_policy_trace_id: Vec<String>,
    #[arg(long)]
    pub session_id: Option<String>,
    #[arg(long)]
    pub work_item_id: Option<String>,
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..=i64::MAX as u64))]
    pub estimated_tokens: Option<u64>,
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..=i64::MAX as u64))]
    pub estimated_cost_microusd: Option<u64>,
}

impl TaskBoardItemFieldArgs {
    #[must_use]
    pub fn has_external_refs(&self) -> bool {
        !self.external_ref.is_empty()
    }

    #[must_use]
    pub fn external_refs(&self) -> Vec<ExternalRef> {
        self.external_ref
            .iter()
            .map(ExternalRefArg::as_external_ref)
            .collect()
    }

    #[must_use]
    pub fn planning(&self) -> Option<PlanningState> {
        if self.planning_summary.is_none()
            && self.approved_by.is_none()
            && self.approved_at.is_none()
        {
            return None;
        }
        Some(PlanningState {
            summary: self.planning_summary.clone(),
            approved_by: self.approved_by.clone(),
            approved_at: self
                .approved_at
                .clone()
                .or_else(|| self.approved_by.as_ref().map(|_| utc_now())),
        })
    }

    #[must_use]
    pub fn has_workflow_update(&self) -> bool {
        self.workflow_execution_id.is_some()
            || self.workflow_status.is_some()
            || self.workflow_current_step_id.is_some()
            || self.workflow_attempts.is_some()
            || self.workflow_branch.is_some()
            || self.workflow_worktree.is_some()
            || self.workflow_pr_number.is_some()
            || self.workflow_pr_url.is_some()
            || self.workflow_last_error.is_some()
            || !self.workflow_policy_trace_id.is_empty()
    }

    #[must_use]
    pub fn workflow(
        &self,
        current: Option<&TaskBoardWorkflowState>,
    ) -> Option<TaskBoardWorkflowState> {
        if !self.has_workflow_update() {
            return None;
        }
        let mut workflow = current.cloned().unwrap_or_default();
        assign_if_some(
            &mut workflow.execution_id,
            self.workflow_execution_id.as_ref(),
        );
        assign_copy_if_some(&mut workflow.status, self.workflow_status);
        assign_if_some(
            &mut workflow.current_step_id,
            self.workflow_current_step_id.as_ref(),
        );
        assign_copy_if_some(&mut workflow.attempts, self.workflow_attempts);
        assign_if_some(&mut workflow.branch, self.workflow_branch.as_ref());
        assign_if_some(&mut workflow.worktree, self.workflow_worktree.as_ref());
        assign_copy_if_some_option(&mut workflow.pr_number, self.workflow_pr_number);
        assign_if_some(&mut workflow.pr_url, self.workflow_pr_url.as_ref());
        assign_if_some(&mut workflow.last_error, self.workflow_last_error.as_ref());
        if !self.workflow_policy_trace_id.is_empty() {
            workflow
                .policy_trace_ids
                .clone_from(&self.workflow_policy_trace_id);
        }
        Some(workflow)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalRefArg {
    provider: ExternalRefProvider,
    external_id: String,
    url: Option<String>,
}

impl ExternalRefArg {
    #[must_use]
    pub fn as_external_ref(&self) -> ExternalRef {
        ExternalRef {
            provider: self.provider,
            external_id: self.external_id.clone(),
            url: self.url.clone(),
            sync_state: None,
        }
    }
}

impl FromStr for ExternalRefArg {
    type Err = CliError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let (provider, rest) = value.split_once(':').ok_or_else(|| {
            CliErrorKind::workflow_parse(
                "external ref must be provider:external_id or provider:external_id=url",
            )
        })?;
        let provider = parse_provider(provider)?;
        let (external_id, url) = rest
            .split_once('=')
            .map_or((rest, None), |(id, url)| (id, Some(url)));
        let external_id = external_id.trim();
        if external_id.is_empty() {
            return Err(CliErrorKind::workflow_parse("external ref id cannot be empty").into());
        }
        Ok(Self {
            provider,
            external_id: external_id.to_string(),
            url: url
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string),
        })
    }
}

fn parse_provider(provider: &str) -> Result<ExternalRefProvider, CliError> {
    match provider.trim().to_ascii_lowercase().as_str() {
        "github" => Ok(ExternalRefProvider::GitHub),
        "todoist" => Ok(ExternalRefProvider::Todoist),
        other => Err(CliErrorKind::workflow_parse(format!(
            "unsupported external ref provider '{other}'"
        ))
        .into()),
    }
}

fn assign_if_some(target: &mut Option<String>, value: Option<&String>) {
    if let Some(value) = value {
        *target = Some(value.clone());
    }
}

fn assign_copy_if_some<T: Copy>(target: &mut T, value: Option<T>) {
    if let Some(value) = value {
        *target = value;
    }
}

fn assign_copy_if_some_option<T: Copy>(target: &mut Option<T>, value: Option<T>) {
    if let Some(value) = value {
        *target = Some(value);
    }
}
