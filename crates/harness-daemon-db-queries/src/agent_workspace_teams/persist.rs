use std::collections::{BTreeMap, BTreeSet};

use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_protocol::daemon::summaries::{
    AgentWorkspaceTeamConflict, AgentWorkspaceTeamConflictKind,
};
use sqlx::{FromRow, Sqlite, Transaction, query, query_as};

use super::identity::team_shadow_digest;
use super::model::{MemberPlan, MemberProvenancePlan, TeamPlan};
use super::status::{
    liveness_label, membership_label, parse_liveness, parse_membership, parse_runtime_lifecycle,
    runtime_lifecycle_label,
};

#[derive(Debug, Clone, FromRow)]
pub(super) struct StoredTeamRow {
    pub(super) workspace_id: String,
    pub(super) authority: String,
    pub(super) selected_legacy_session_id: Option<String>,
    pub(super) selected_lifecycle: Option<String>,
    pub(super) leader_member_id: Option<String>,
    pub(super) source_revision: i64,
    pub(super) shadow_digest: String,
    pub(super) created_at: String,
    pub(super) updated_at: String,
}

#[derive(Debug, Clone, FromRow)]
pub(super) struct StoredMemberRow {
    pub(super) member_id: String,
    pub(super) runtime_kind: String,
    pub(super) managed_agent_kind: Option<String>,
    pub(super) managed_agent_id: Option<String>,
    pub(super) display_name: String,
    pub(super) role: Option<String>,
    pub(super) membership_status: String,
    pub(super) liveness_status: String,
    pub(super) runtime_session_id: Option<String>,
    pub(super) assignment_id: Option<String>,
    pub(super) runtime_lifecycle: String,
    pub(super) runtime_evidence: String,
    pub(super) source_session_id: Option<String>,
    pub(super) source_agent_id: Option<String>,
    pub(super) source_digest: String,
    pub(super) membership_source_digest: String,
    pub(super) runtime_source_digest: String,
    pub(super) membership_override_source_digest: Option<String>,
    pub(super) runtime_override_source_digest: Option<String>,
    pub(super) joined_at: Option<String>,
    pub(super) last_activity_at: Option<String>,
    pub(super) created_at: String,
    pub(super) updated_at: String,
}

#[derive(Debug, Clone, FromRow)]
pub(super) struct StoredProvenanceRow {
    pub(super) member_id: String,
    pub(super) source_session_id: String,
    pub(super) source_agent_id: String,
    pub(super) source_digest: String,
    pub(super) is_selected: i64,
}

pub(super) async fn validate_team_shadow(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<Option<AgentWorkspaceTeamConflict>, CliError> {
    let Some((team, members, provenance)) = load_stored_plan(transaction, workspace_id).await?
    else {
        return Ok(None);
    };
    let plan = stored_plan(&team, members, provenance)?;
    let computed = team_shadow_digest(&plan, &team.created_at);
    Ok(
        (computed != team.shadow_digest).then(|| AgentWorkspaceTeamConflict {
            kind: AgentWorkspaceTeamConflictKind::SourceDisagreement,
            legacy_session_ids: plan
                .members
                .iter()
                .flat_map(|member| member.provenance.iter())
                .map(|source| source.source_session_id.clone())
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect(),
            managed_identity: None,
            detail: "durable agent team shadow does not match its verified digest".to_string(),
        }),
    )
}

pub(super) async fn persist_team_plan(
    transaction: &mut Transaction<'_, Sqlite>,
    plan: &TeamPlan,
) -> Result<(), CliError> {
    let created_at = plan.created_at.as_deref().unwrap_or(&plan.updated_at);
    query(
        "INSERT INTO agent_workspace_teams (
            workspace_id, authority, selected_legacy_session_id, selected_lifecycle,
            leader_member_id, source_revision, reconciled_revision, shadow_digest,
            created_at, updated_at
         ) VALUES (?1, 'workspace', ?2, ?3, ?4, ?5, ?5, '', ?6, ?7)
         ON CONFLICT(workspace_id) DO UPDATE SET
            authority = 'workspace',
            selected_legacy_session_id = excluded.selected_legacy_session_id,
            selected_lifecycle = excluded.selected_lifecycle,
            leader_member_id = excluded.leader_member_id,
            reconciled_revision = excluded.source_revision,
            updated_at = excluded.updated_at",
    )
    .bind(&plan.workspace_id)
    .bind(&plan.selected_legacy_session_id)
    .bind(&plan.selected_lifecycle)
    .bind(&plan.leader_member_id)
    .bind(plan.source_revision)
    .bind(created_at)
    .bind(&plan.updated_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist durable agent team: {error}")))?;

    let current_ids = plan
        .members
        .iter()
        .map(|member| member.member_id.as_str())
        .collect::<Vec<_>>();
    for member in &plan.members {
        persist_member(transaction, &plan.workspace_id, member).await?;
    }
    mark_missing_members_removed(
        transaction,
        &plan.workspace_id,
        &current_ids,
        &plan.updated_at,
    )
    .await?;
    refresh_shadow_digest(transaction, &plan.workspace_id).await
}

pub(super) async fn finalize_detached_team(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<(), CliError> {
    let shadow = query_as::<_, (String,)>(
        "SELECT shadow_digest FROM agent_workspace_teams
         WHERE workspace_id = ?1 AND selected_legacy_session_id IS NULL",
    )
    .bind(workspace_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("inspect detached agent team: {error}")))?;
    let Some((shadow_digest,)) = shadow else {
        return Ok(());
    };
    if shadow_digest.is_empty() {
        refresh_shadow_digest(transaction, workspace_id).await?;
    }
    query(
        "UPDATE agent_workspace_teams
         SET reconciled_revision = source_revision
         WHERE workspace_id = ?1",
    )
    .bind(workspace_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("finalize detached agent team: {error}")))?;
    Ok(())
}

const UPSERT_MEMBER_SQL: &str = "INSERT INTO agent_workspace_members (
            workspace_id, member_id, runtime_kind, managed_agent_kind,
            managed_agent_id, display_name, role, membership_status,
            liveness_status, runtime_session_id, assignment_id, runtime_lifecycle,
            runtime_evidence, source_session_id, source_agent_id, source_digest,
            membership_source_digest, runtime_source_digest,
            membership_override_source_digest, runtime_override_source_digest,
            joined_at, last_activity_at, created_at, updated_at
         ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
            ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, NULL, NULL,
            ?19, ?20, ?21, ?22
         )
         ON CONFLICT(workspace_id, member_id) DO UPDATE SET
            runtime_kind = excluded.runtime_kind,
            managed_agent_kind = excluded.managed_agent_kind,
            managed_agent_id = excluded.managed_agent_id,
            display_name = excluded.display_name,
            role = excluded.role,
            membership_status = CASE
                WHEN excluded.membership_source_digest = ''
                     AND agent_workspace_members.membership_source_digest <> ''
                THEN 'removed'
                WHEN agent_workspace_members.membership_override_source_digest IS NOT NULL
                THEN 'removed' ELSE excluded.membership_status END,
            liveness_status = CASE
                WHEN excluded.membership_source_digest = ''
                     AND agent_workspace_members.membership_source_digest <> ''
                THEN 'removed'
                WHEN agent_workspace_members.membership_override_source_digest IS NOT NULL
                THEN 'removed' ELSE excluded.liveness_status END,
            runtime_session_id = excluded.runtime_session_id,
            assignment_id = excluded.assignment_id,
            runtime_lifecycle = CASE
                WHEN excluded.membership_status = 'removed'
                THEN agent_workspace_members.runtime_lifecycle
                WHEN agent_workspace_members.runtime_override_source_digest
                     = excluded.runtime_source_digest
                THEN 'completed' ELSE excluded.runtime_lifecycle END,
            runtime_evidence = CASE
                WHEN excluded.membership_status = 'removed'
                THEN agent_workspace_members.runtime_evidence
                WHEN agent_workspace_members.runtime_override_source_digest
                     = excluded.runtime_source_digest
                THEN 'runtime_stop_succeeded' ELSE excluded.runtime_evidence END,
            source_session_id = excluded.source_session_id,
            source_agent_id = excluded.source_agent_id,
            source_digest = excluded.source_digest,
            membership_source_digest = CASE
                WHEN excluded.membership_source_digest = ''
                     AND agent_workspace_members.membership_source_digest <> ''
                THEN agent_workspace_members.membership_source_digest
                ELSE excluded.membership_source_digest END,
            runtime_source_digest = CASE
                WHEN excluded.membership_status = 'removed'
                THEN agent_workspace_members.runtime_source_digest
                ELSE excluded.runtime_source_digest END,
            membership_override_source_digest = CASE
                WHEN excluded.membership_source_digest = ''
                     AND agent_workspace_members.membership_source_digest <> ''
                THEN agent_workspace_members.membership_override_source_digest
                ELSE agent_workspace_members.membership_override_source_digest END,
            runtime_override_source_digest = CASE
                WHEN excluded.membership_status = 'removed'
                THEN agent_workspace_members.runtime_override_source_digest
                WHEN agent_workspace_members.runtime_override_source_digest
                     = excluded.runtime_source_digest
                THEN agent_workspace_members.runtime_override_source_digest END,
            joined_at = excluded.joined_at,
            last_activity_at = excluded.last_activity_at,
            updated_at = excluded.updated_at";

async fn persist_member(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member: &MemberPlan,
) -> Result<(), CliError> {
    query(UPSERT_MEMBER_SQL)
        .bind(workspace_id)
        .bind(&member.member_id)
        .bind(&member.runtime_kind)
        .bind(&member.managed_agent_kind)
        .bind(&member.managed_agent_id)
        .bind(&member.display_name)
        .bind(&member.role)
        .bind(membership_label(member.membership_status))
        .bind(liveness_label(member.liveness_status))
        .bind(&member.runtime_session_id)
        .bind(&member.assignment_id)
        .bind(runtime_lifecycle_label(member.runtime_lifecycle))
        .bind(&member.runtime_evidence)
        .bind(&member.source_session_id)
        .bind(&member.source_agent_id)
        .bind(&member.source_digest)
        .bind(&member.membership_source_digest)
        .bind(&member.runtime_source_digest)
        .bind(&member.joined_at)
        .bind(&member.last_activity_at)
        .bind(&member.created_at)
        .bind(&member.updated_at)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("persist durable agent team member: {error}")))?;
    replace_provenance(transaction, workspace_id, member).await
}

async fn replace_provenance(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member: &MemberPlan,
) -> Result<(), CliError> {
    query(
        "DELETE FROM agent_workspace_member_provenance
         WHERE workspace_id = ?1 AND member_id = ?2
           AND source_session_id IN (SELECT session_id FROM sessions)",
    )
    .bind(workspace_id)
    .bind(&member.member_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("replace agent team provenance: {error}")))?;
    for source in &member.provenance {
        query(
            "INSERT INTO agent_workspace_member_provenance (
                workspace_id, member_id, source_session_id, source_agent_id,
                source_digest, is_selected
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        )
        .bind(workspace_id)
        .bind(&member.member_id)
        .bind(&source.source_session_id)
        .bind(&source.source_agent_id)
        .bind(&source.source_digest)
        .bind(source.is_selected)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("persist agent team provenance: {error}")))?;
    }
    Ok(())
}

async fn mark_missing_members_removed(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_ids: &[&str],
    now: &str,
) -> Result<(), CliError> {
    let member_ids = serde_json::to_string(member_ids)
        .map_err(|error| db_error(format!("serialize current agent team members: {error}")))?;
    query(
        "UPDATE agent_workspace_members
         SET membership_status = 'removed', liveness_status = 'removed',
             runtime_lifecycle = 'unavailable', runtime_evidence = 'source_missing',
             source_digest = '', updated_at = ?3
         WHERE workspace_id = ?1
           AND member_id NOT IN (SELECT value FROM json_each(?2))
           AND (
               source_session_id IS NULL
               OR EXISTS (
                   SELECT 1 FROM sessions source_session
                   WHERE source_session.session_id = agent_workspace_members.source_session_id
               )
           )",
    )
    .bind(workspace_id)
    .bind(member_ids)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("retire absent agent team members: {error}")))?;
    Ok(())
}

pub(super) async fn refresh_shadow_digest(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<(), CliError> {
    let Some((team, members, provenance)) = load_stored_plan(transaction, workspace_id).await?
    else {
        return Err(db_error("refresh agent team shadow: team disappeared"));
    };
    let plan = stored_plan(&team, members, provenance)?;
    let shadow_digest = team_shadow_digest(&plan, &team.created_at);
    query("UPDATE agent_workspace_teams SET shadow_digest = ?2 WHERE workspace_id = ?1")
        .bind(workspace_id)
        .bind(shadow_digest)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("refresh agent team shadow: {error}")))?;
    Ok(())
}

pub(super) async fn load_stored_plan(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<
    Option<(
        StoredTeamRow,
        Vec<StoredMemberRow>,
        Vec<StoredProvenanceRow>,
    )>,
    CliError,
> {
    let team = query_as::<_, StoredTeamRow>(
        "SELECT workspace_id, authority, selected_legacy_session_id,
                selected_lifecycle, leader_member_id, source_revision,
                shadow_digest, created_at, updated_at
         FROM agent_workspace_teams WHERE workspace_id = ?1",
    )
    .bind(workspace_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable agent team: {error}")))?;
    let Some(team) = team else {
        return Ok(None);
    };
    let members = query_as::<_, StoredMemberRow>(
        "SELECT member_id, runtime_kind, managed_agent_kind,
                managed_agent_id, display_name, role, membership_status,
                liveness_status, runtime_session_id, assignment_id, runtime_lifecycle,
                runtime_evidence, source_session_id, source_agent_id, source_digest,
                membership_source_digest, runtime_source_digest,
                membership_override_source_digest, runtime_override_source_digest,
                joined_at, last_activity_at, created_at, updated_at
         FROM agent_workspace_members WHERE workspace_id = ?1 ORDER BY member_id",
    )
    .bind(workspace_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable agent team members: {error}")))?;
    let provenance = query_as::<_, StoredProvenanceRow>(
        "SELECT member_id, source_session_id, source_agent_id,
                source_digest, is_selected
         FROM agent_workspace_member_provenance
         WHERE workspace_id = ?1
         ORDER BY member_id, source_session_id, source_agent_id",
    )
    .bind(workspace_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable agent team provenance: {error}")))?;
    Ok(Some((team, members, provenance)))
}

fn stored_plan(
    team: &StoredTeamRow,
    members: Vec<StoredMemberRow>,
    provenance: Vec<StoredProvenanceRow>,
) -> Result<TeamPlan, CliError> {
    let provenance = provenance_plan_by_member(provenance);
    let members = members
        .into_iter()
        .map(|member| member_plan(member, &provenance))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(TeamPlan {
        workspace_id: team.workspace_id.clone(),
        authority: team.authority.clone(),
        selected_legacy_session_id: team.selected_legacy_session_id.clone(),
        selected_lifecycle: team.selected_lifecycle.clone(),
        leader_member_id: team.leader_member_id.clone(),
        source_revision: team.source_revision,
        created_at: Some(team.created_at.clone()),
        updated_at: team.updated_at.clone(),
        members,
    })
}

fn member_plan(
    member: StoredMemberRow,
    provenance: &BTreeMap<String, Vec<MemberProvenancePlan>>,
) -> Result<MemberPlan, CliError> {
    Ok(MemberPlan {
        member_id: member.member_id.clone(),
        runtime_kind: member.runtime_kind,
        managed_agent_kind: member.managed_agent_kind,
        managed_agent_id: member.managed_agent_id,
        display_name: member.display_name,
        role: member.role,
        membership_status: parse_membership(&member.membership_status)?,
        liveness_status: parse_liveness(&member.liveness_status)?,
        runtime_session_id: member.runtime_session_id,
        assignment_id: member.assignment_id,
        runtime_lifecycle: parse_runtime_lifecycle(&member.runtime_lifecycle)?,
        runtime_evidence: member.runtime_evidence,
        source_session_id: member.source_session_id,
        source_agent_id: member.source_agent_id,
        source_digest: member.source_digest,
        membership_source_digest: member.membership_source_digest,
        runtime_source_digest: member.runtime_source_digest,
        membership_override_source_digest: member.membership_override_source_digest,
        runtime_override_source_digest: member.runtime_override_source_digest,
        joined_at: member.joined_at,
        last_activity_at: member.last_activity_at,
        created_at: member.created_at,
        updated_at: member.updated_at,
        provenance: provenance
            .get(&member.member_id)
            .cloned()
            .unwrap_or_default(),
    })
}

fn provenance_plan_by_member(
    rows: Vec<StoredProvenanceRow>,
) -> BTreeMap<String, Vec<MemberProvenancePlan>> {
    let mut result: BTreeMap<String, Vec<MemberProvenancePlan>> = BTreeMap::new();
    for row in rows {
        result
            .entry(row.member_id)
            .or_default()
            .push(MemberProvenancePlan {
                source_session_id: row.source_session_id,
                source_agent_id: row.source_agent_id,
                source_digest: row.source_digest,
                is_selected: row.is_selected == 1,
            });
    }
    result
}
