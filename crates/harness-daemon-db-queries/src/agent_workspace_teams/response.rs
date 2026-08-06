use std::collections::BTreeMap;

use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_protocol::daemon::summaries::{
    AgentWorkspaceMemberOperationKind, AgentWorkspaceMemberOperationOutcome,
    AgentWorkspaceMemberOperationResult, AgentWorkspaceMemberProvenance,
    AgentWorkspaceMemberSummary, AgentWorkspaceTeamAuthority, AgentWorkspaceTeamConflict,
    AgentWorkspaceTeamResponse, AgentWorkspaceTeamSummary,
};
use sqlx::{FromRow, Sqlite, Transaction, query_as};

use super::model::{managed_identity, role};
use super::persist::{StoredMemberRow, StoredProvenanceRow, load_stored_plan};
use super::status::{parse_liveness, parse_membership, parse_runtime_lifecycle};

#[derive(Debug, Clone, FromRow)]
struct StoredOperationRow {
    member_id: String,
    operation_id: String,
    operation_kind: String,
    outcome: String,
    before_state: String,
    after_state: String,
    detail: Option<String>,
    recorded_at: String,
}

pub(super) async fn load_team_response(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    conflicts: Vec<AgentWorkspaceTeamConflict>,
) -> Result<AgentWorkspaceTeamResponse, CliError> {
    let Some((team, members, provenance)) = load_stored_plan(transaction, workspace_id).await?
    else {
        return Ok(AgentWorkspaceTeamResponse {
            team: None,
            conflicts,
        });
    };
    let operations = load_operations(transaction, workspace_id).await?;
    let provenance = provenance_by_member(provenance);
    let operations = operations_by_member(operations)?;
    let members = members
        .into_iter()
        .map(|member| member_summary(member, &provenance, &operations))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(AgentWorkspaceTeamResponse {
        team: Some(AgentWorkspaceTeamSummary {
            workspace_id: team.workspace_id,
            authority: parse_authority(&team.authority)?,
            leader_member_id: team.leader_member_id,
            members,
            created_at: team.created_at,
            updated_at: team.updated_at,
        }),
        conflicts,
    })
}

fn provenance_by_member(
    rows: Vec<StoredProvenanceRow>,
) -> BTreeMap<String, Vec<AgentWorkspaceMemberProvenance>> {
    let mut result: BTreeMap<String, Vec<AgentWorkspaceMemberProvenance>> = BTreeMap::new();
    for row in rows {
        result
            .entry(row.member_id)
            .or_default()
            .push(AgentWorkspaceMemberProvenance {
                legacy_session_id: Some(row.source_session_id),
                legacy_agent_id: Some(row.source_agent_id),
            });
    }
    result
}

fn member_summary(
    member: StoredMemberRow,
    provenance: &BTreeMap<String, Vec<AgentWorkspaceMemberProvenance>>,
    operations: &BTreeMap<String, Vec<AgentWorkspaceMemberOperationResult>>,
) -> Result<AgentWorkspaceMemberSummary, CliError> {
    Ok(AgentWorkspaceMemberSummary {
        member_id: member.member_id.clone(),
        runtime_kind: member.runtime_kind,
        managed_identity: managed_identity(
            member.managed_agent_kind.as_deref(),
            member.managed_agent_id.as_deref(),
        )
        .map_err(db_error)?,
        display_name: member.display_name,
        role: member
            .role
            .as_deref()
            .map(role)
            .transpose()
            .map_err(db_error)?,
        membership_status: parse_membership(&member.membership_status)?,
        liveness_status: parse_liveness(&member.liveness_status)?,
        runtime_session_id: member.runtime_session_id,
        assignment_id: member.assignment_id,
        runtime_lifecycle: parse_runtime_lifecycle(&member.runtime_lifecycle)?,
        runtime_evidence: member.runtime_evidence,
        provenance: provenance
            .get(&member.member_id)
            .cloned()
            .unwrap_or_default(),
        joined_at: member.joined_at,
        last_activity_at: member.last_activity_at,
        recent_operations: operations
            .get(&member.member_id)
            .cloned()
            .unwrap_or_default(),
        updated_at: member.updated_at,
    })
}

async fn load_operations(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<Vec<StoredOperationRow>, CliError> {
    query_as::<_, StoredOperationRow>(
        "SELECT member_id, operation_id, operation_kind, outcome,
                before_state, after_state, detail, recorded_at
         FROM (
             SELECT member_id, operation_id, operation_kind, outcome,
                    before_state, after_state, detail, recorded_at,
                    operation_sequence,
                    row_number() OVER (
                        PARTITION BY member_id
                        ORDER BY operation_sequence DESC
                    ) AS operation_rank
             FROM agent_workspace_member_operations
             WHERE workspace_id = ?1
         )
         WHERE operation_rank <= 10
         ORDER BY member_id, operation_sequence DESC",
    )
    .bind(workspace_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load agent team operation results: {error}")))
}

fn operations_by_member(
    rows: Vec<StoredOperationRow>,
) -> Result<BTreeMap<String, Vec<AgentWorkspaceMemberOperationResult>>, CliError> {
    let mut result: BTreeMap<String, Vec<AgentWorkspaceMemberOperationResult>> = BTreeMap::new();
    for row in rows {
        let operations = result.entry(row.member_id).or_default();
        if operations.len() >= 10 {
            continue;
        }
        operations.push(AgentWorkspaceMemberOperationResult {
            operation_id: row.operation_id,
            kind: parse_operation_kind(&row.operation_kind)?,
            outcome: parse_operation_outcome(&row.outcome)?,
            before_state: row.before_state,
            after_state: row.after_state,
            detail: row.detail,
            recorded_at: row.recorded_at,
        });
    }
    Ok(result)
}

fn parse_authority(value: &str) -> Result<AgentWorkspaceTeamAuthority, CliError> {
    match value {
        "legacy_session" => Ok(AgentWorkspaceTeamAuthority::LegacySession),
        "workspace" => Ok(AgentWorkspaceTeamAuthority::Workspace),
        _ => Err(db_error(format!("unknown agent team authority '{value}'"))),
    }
}

fn parse_operation_kind(value: &str) -> Result<AgentWorkspaceMemberOperationKind, CliError> {
    match value {
        "runtime_stop" => Ok(AgentWorkspaceMemberOperationKind::RuntimeStop),
        "membership_remove" => Ok(AgentWorkspaceMemberOperationKind::MembershipRemove),
        _ => Err(db_error(format!("unknown agent team operation '{value}'"))),
    }
}

fn parse_operation_outcome(value: &str) -> Result<AgentWorkspaceMemberOperationOutcome, CliError> {
    match value {
        "succeeded" => Ok(AgentWorkspaceMemberOperationOutcome::Succeeded),
        "failed" => Ok(AgentWorkspaceMemberOperationOutcome::Failed),
        _ => Err(db_error(format!(
            "unknown agent team operation outcome '{value}'"
        ))),
    }
}
