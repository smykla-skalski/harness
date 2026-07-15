use clap::{ArgAction, Args, Subcommand};
use serde::Serialize;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::{
    PolicyApprovalGrantResolveRequest, PolicyApprovalGrantRevokeRequest,
    PolicyApprovalGrantsListResponse,
    PolicyCanvasSetSpawnKillSwitchRequest, PolicyCanvasSetSpawnRequiresLivePolicyRequest,
    PolicyCanvasWorkspaceResponse,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{PolicyApprovalGrant, PolicyApprovalState};

use super::policy_io::{TaskBoardPolicyDumpArgs, TaskBoardPolicyImportArgs};
use super::{daemon_client, print_json};

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum TaskBoardPolicyCommand {
    /// Dump policy canvases as a portable JSON bundle.
    #[command(visible_alias = "export")]
    Dump(TaskBoardPolicyDumpArgs),
    /// Import policy canvases from JSON files or standard input.
    Import(TaskBoardPolicyImportArgs),
    /// List pending approval grants.
    #[command(visible_alias = "approval-grants-list")]
    Grants(TaskBoardPolicyJsonArgs),
    /// Approve or deny one pending approval grant.
    #[command(visible_alias = "approval-grant-resolve")]
    GrantResolve(TaskBoardPolicyGrantResolveArgs),
    /// Revoke one approval grant.
    #[command(visible_alias = "approval-grant-revoke")]
    GrantRevoke(TaskBoardPolicyGrantRevokeArgs),
    /// Toggle the fail-closed live-policy requirement for worker spawning.
    #[command(visible_alias = "set-spawn-requires-live-policy")]
    SpawnRequiresLivePolicy(TaskBoardPolicyToggleArgs),
    /// Toggle the emergency worker-spawn kill switch.
    #[command(visible_alias = "set-spawn-kill-switch")]
    SpawnKillSwitch(TaskBoardPolicyToggleArgs),
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPolicyJsonArgs {
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPolicyGrantResolveArgs {
    pub grant_id: String,
    #[arg(long, required_unless_present = "deny", conflicts_with = "deny")]
    pub approve: bool,
    #[arg(long, required_unless_present = "approve", conflicts_with = "approve")]
    pub deny: bool,
    #[arg(long)]
    pub actor: Option<String>,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPolicyGrantRevokeArgs {
    pub grant_id: String,
    #[arg(long)]
    pub actor: Option<String>,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPolicyToggleArgs {
    #[arg(long, action = ArgAction::Set, required = true)]
    pub enabled: bool,
    #[arg(long)]
    pub json: bool,
}

impl Execute for TaskBoardPolicyCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Dump(args) => args.execute(context),
            Self::Import(args) => args.execute(context),
            Self::Grants(args) => args.execute(context),
            Self::GrantResolve(args) => args.execute(context),
            Self::GrantRevoke(args) => args.execute(context),
            Self::SpawnRequiresLivePolicy(args) => args.execute_spawn_requires_live_policy(context),
            Self::SpawnKillSwitch(args) => args.execute_spawn_kill_switch(context),
        }
    }
}

impl Execute for TaskBoardPolicyJsonArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response = daemon_client()?.list_policy_approval_grants()?;
        if self.json {
            print_json(&response)?;
        } else {
            print_grants(&response)?;
        }
        Ok(0)
    }
}

impl Execute for TaskBoardPolicyGrantResolveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response =
            daemon_client()?.resolve_policy_approval_grant(&PolicyApprovalGrantResolveRequest {
                grant_id: self.grant_id.clone(),
                approve: self.approve,
                actor: self.actor.clone(),
            })?;
        if self.json {
            print_json(&response)?;
        } else {
            print_resolved_grant(&response.grant);
        }
        Ok(0)
    }
}

impl Execute for TaskBoardPolicyGrantRevokeArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response =
            daemon_client()?.revoke_policy_approval_grant(&PolicyApprovalGrantRevokeRequest {
                grant_id: self.grant_id.clone(),
                actor: self.actor.clone(),
            })?;
        if self.json {
            print_json(&response)?;
        } else {
            print_resolved_grant(&response.grant);
        }
        Ok(0)
    }
}

impl TaskBoardPolicyToggleArgs {
    fn execute_spawn_requires_live_policy(&self, _context: &AppContext) -> Result<i32, CliError> {
        let workspace = daemon_client()?.set_policy_canvas_spawn_requires_live_policy(
            &PolicyCanvasSetSpawnRequiresLivePolicyRequest {
                enabled: self.enabled,
            },
        )?;
        print_toggle(
            &workspace,
            self.json,
            "spawn requires live policy",
            workspace.spawn_requires_live_policy,
        )
    }

    fn execute_spawn_kill_switch(&self, _context: &AppContext) -> Result<i32, CliError> {
        let workspace = daemon_client()?.set_policy_canvas_spawn_kill_switch(
            &PolicyCanvasSetSpawnKillSwitchRequest {
                enabled: self.enabled,
            },
        )?;
        print_toggle(
            &workspace,
            self.json,
            "spawn kill switch",
            workspace.spawn_kill_switch,
        )
    }
}

fn print_grants(response: &PolicyApprovalGrantsListResponse) -> Result<(), CliError> {
    if response.grants.is_empty() {
        println!("no pending approval grants");
        return Ok(());
    }
    for grant in &response.grants {
        println!(
            "[{}] {}: {} ({})",
            serialized_label(&grant.state)?,
            grant.id,
            grant.board_item_id,
            serialized_label(&grant.action)?
        );
    }
    Ok(())
}

fn serialized_label<T: Serialize>(value: &T) -> Result<String, CliError> {
    let value = serde_json::to_value(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    value.as_str().map(str::to_owned).ok_or_else(|| {
        CliErrorKind::workflow_serialize("expected policy enum to serialize as a string").into()
    })
}

fn print_resolved_grant(grant: &PolicyApprovalGrant) {
    let resolution = match grant.state {
        PolicyApprovalState::Approved => "approved",
        PolicyApprovalState::Denied => "denied",
        PolicyApprovalState::Pending => "pending",
        PolicyApprovalState::Revoked => "revoked",
    };
    println!(
        "approval grant {}: {resolution} by {}",
        grant.id,
        grant.resolved_by.as_deref().unwrap_or("<unset>")
    );
}

fn print_toggle(
    workspace: &PolicyCanvasWorkspaceResponse,
    json: bool,
    label: &str,
    enabled: bool,
) -> Result<i32, CliError> {
    if json {
        print_json(workspace)?;
    } else {
        println!("{label}: {}", if enabled { "enabled" } else { "disabled" });
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::PolicyAction;

    #[test]
    fn serialized_policy_labels_match_wire_values() {
        assert_eq!(
            serialized_label(&PolicyApprovalState::Pending).expect("serialize approval state"),
            "pending"
        );
        assert_eq!(
            serialized_label(&PolicyAction::SpawnAgent).expect("serialize policy action"),
            "spawn_agent"
        );
    }
}
