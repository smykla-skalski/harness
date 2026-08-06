use std::collections::BTreeMap;

use harness_protocol::daemon::summaries::{
    AgentWorkspaceLivenessStatus, AgentWorkspaceMembershipStatus, AgentWorkspaceRuntimeLifecycle,
    AgentWorkspaceTeamConflict,
};
use serde_json::Value;

use super::evidence::{
    codex_digest, codex_operation_marker, registration_digest, registration_operation_marker,
    registration_runtime_evidence, registration_runtime_lifecycle, runtime_evidence, tui_digest,
    tui_operation_marker,
};
use super::identity::{legacy_member_id, managed_member_id};
use super::model::{
    MemberKey, MemberPlan, MemberProvenancePlan, TeamPlan, identity_conflict, malformed_conflict,
};
use super::source::{CodexRow, RegistrationRow, TuiRow, WorkspaceSources};
use super::validation::registration_key;

pub(super) fn build_team_plan(
    sources: &WorkspaceSources,
    now: &str,
) -> Result<Option<TeamPlan>, AgentWorkspaceTeamConflict> {
    let workspace = &sources.workspace;
    let Some(selected_session_id) = workspace.selected_legacy_session_id.as_deref() else {
        return Ok(None);
    };
    let recorded_lifecycle = workspace.selected_lifecycle.as_deref().unwrap_or("ended");
    let selected_lifecycle = if recorded_lifecycle != "ended"
        && selected_runtime_is_live(sources, selected_session_id)
    {
        "active"
    } else {
        recorded_lifecycle
    };
    let mut members = BTreeMap::new();
    for registration in &sources.registrations {
        merge_registration(
            &mut members,
            &workspace.workspace_id,
            selected_session_id,
            registration,
        )?;
    }
    for tui in &sources.tuis {
        merge_tui(
            &mut members,
            &workspace.workspace_id,
            selected_session_id,
            tui,
        )?;
    }
    for run in &sources.codex_runs {
        merge_codex(
            &mut members,
            &workspace.workspace_id,
            selected_session_id,
            run,
        )?;
    }
    let members = members.into_values().collect::<Vec<_>>();
    let leader_member_id = leader_member_id(
        &members,
        selected_session_id,
        selected_lifecycle,
        workspace.leader_agent_id.as_deref(),
    );
    Ok(Some(TeamPlan {
        workspace_id: workspace.workspace_id.clone(),
        authority: "workspace".to_string(),
        selected_legacy_session_id: Some(selected_session_id.to_string()),
        selected_lifecycle: Some(selected_lifecycle.to_string()),
        leader_member_id,
        source_revision: workspace.source_revision.unwrap_or(1).max(1),
        created_at: workspace.team_created_at.clone(),
        updated_at: now.to_string(),
        members,
    }))
}

fn selected_runtime_is_live(sources: &WorkspaceSources, selected_session_id: &str) -> bool {
    sources.registrations.iter().any(|row| {
        row.session_id == selected_session_id
            && matches!(
                liveness_status(&row.status),
                AgentWorkspaceLivenessStatus::Active
                    | AgentWorkspaceLivenessStatus::Idle
                    | AgentWorkspaceLivenessStatus::AwaitingReview
            )
    }) || sources.tuis.iter().any(|row| {
        row.session_id == selected_session_id
            && matches!(row.status.as_str(), "starting" | "running")
    }) || sources.codex_runs.iter().any(|row| {
        row.session_id == selected_session_id
            && matches!(
                row.status.as_str(),
                "queued" | "running" | "waiting_approval"
            )
    })
}

fn merge_registration(
    members: &mut BTreeMap<MemberKey, MemberPlan>,
    workspace_id: &str,
    selected_session_id: &str,
    row: &RegistrationRow,
) -> Result<(), AgentWorkspaceTeamConflict> {
    let key = registration_key(row)?;
    let is_selected = row.session_id == selected_session_id;
    let source_digest = registration_digest(row);
    let source_marker = registration_operation_marker(row);
    let provenance = MemberProvenancePlan {
        source_session_id: row.session_id.clone(),
        source_agent_id: row.agent_id.clone(),
        source_digest: source_digest.clone(),
        is_selected,
    };
    if let Some(member) = members.get_mut(&key) {
        validate_binding(member, row, &key)?;
        member.provenance.push(provenance);
        if is_selected {
            apply_registration(member, row, &source_digest, &source_marker, true);
        }
        return Ok(());
    }
    let (managed_agent_kind, managed_agent_id, member_id) = match &key {
        MemberKey::Managed { kind, id } => (
            Some(kind.clone()),
            Some(id.clone()),
            managed_member_id(workspace_id, kind, id),
        ),
        MemberKey::Legacy {
            session_id,
            agent_id,
        } => (
            None,
            None,
            legacy_member_id(workspace_id, session_id, agent_id),
        ),
    };
    let mut member = MemberPlan {
        member_id,
        runtime_kind: row.runtime.clone(),
        managed_agent_kind,
        managed_agent_id,
        display_name: row.name.clone(),
        role: Some(row.role.clone()),
        membership_status: AgentWorkspaceMembershipStatus::Historical,
        liveness_status: AgentWorkspaceLivenessStatus::Unknown,
        runtime_session_id: row.runtime_session_id.clone(),
        assignment_id: row.current_task_id.clone(),
        runtime_lifecycle: registration_runtime_lifecycle(row),
        runtime_evidence: registration_runtime_evidence(row),
        source_session_id: Some(row.session_id.clone()),
        source_agent_id: Some(row.agent_id.clone()),
        source_digest: source_digest.clone(),
        membership_source_digest: source_marker.clone(),
        runtime_source_digest: source_marker.clone(),
        membership_override_source_digest: None,
        runtime_override_source_digest: None,
        joined_at: Some(row.joined_at.clone()),
        last_activity_at: row.last_activity_at.clone(),
        created_at: row.joined_at.clone(),
        updated_at: row.updated_at.clone(),
        provenance: vec![provenance],
    };
    apply_registration(
        &mut member,
        row,
        &source_digest,
        &source_marker,
        is_selected,
    );
    members.insert(key, member);
    Ok(())
}

fn apply_registration(
    member: &mut MemberPlan,
    row: &RegistrationRow,
    source_digest: &str,
    source_marker: &str,
    is_selected: bool,
) {
    member.runtime_kind.clone_from(&row.runtime);
    member.display_name.clone_from(&row.name);
    member.role = Some(row.role.clone());
    member
        .runtime_session_id
        .clone_from(&row.runtime_session_id);
    member.assignment_id.clone_from(&row.current_task_id);
    member.source_session_id = Some(row.session_id.clone());
    member.source_agent_id = Some(row.agent_id.clone());
    member.source_digest = source_digest.to_string();
    member.membership_source_digest = source_marker.to_string();
    member.runtime_source_digest = source_marker.to_string();
    member.joined_at = Some(row.joined_at.clone());
    member.last_activity_at.clone_from(&row.last_activity_at);
    member.updated_at.clone_from(&row.updated_at);
    if is_selected {
        member.liveness_status = liveness_status(&row.status);
        member.runtime_lifecycle = registration_runtime_lifecycle(row);
        member.runtime_evidence = registration_runtime_evidence(row);
        member.membership_status =
            if member.liveness_status == AgentWorkspaceLivenessStatus::Removed {
                AgentWorkspaceMembershipStatus::Removed
            } else {
                AgentWorkspaceMembershipStatus::Joined
            };
    } else {
        member.membership_status = AgentWorkspaceMembershipStatus::Historical;
        member.liveness_status = AgentWorkspaceLivenessStatus::Unknown;
    }
}

fn validate_binding(
    member: &MemberPlan,
    row: &RegistrationRow,
    key: &MemberKey,
) -> Result<(), AgentWorkspaceTeamConflict> {
    let MemberKey::Managed { kind, id } = key else {
        return Ok(());
    };
    validate_managed_runtime_binding(
        member,
        row.runtime_session_id.as_deref(),
        kind,
        id,
        &row.session_id,
    )
}

fn validate_managed_runtime_binding(
    member: &MemberPlan,
    incoming: Option<&str>,
    kind: &str,
    id: &str,
    source_session_id: &str,
) -> Result<(), AgentWorkspaceTeamConflict> {
    let Some(existing) = member.runtime_session_id.as_deref() else {
        return Ok(());
    };
    let Some(incoming) = incoming else {
        return Ok(());
    };
    if existing == incoming {
        return Ok(());
    }
    let mut session_ids = member
        .provenance
        .iter()
        .map(|source| source.source_session_id.clone())
        .collect::<Vec<_>>();
    session_ids.push(source_session_id.to_string());
    session_ids.sort();
    session_ids.dedup();
    Err(identity_conflict(
        session_ids,
        kind,
        id,
        format!("managed runtime identity has conflicting bindings '{existing}' and '{incoming}'"),
    ))
}

fn merge_tui(
    members: &mut BTreeMap<MemberKey, MemberPlan>,
    workspace_id: &str,
    selected_session_id: &str,
    row: &TuiRow,
) -> Result<(), AgentWorkspaceTeamConflict> {
    let key = MemberKey::Managed {
        kind: "tui".to_string(),
        id: row.tui_id.clone(),
    };
    let is_selected = row.session_id == selected_session_id;
    let member = members.entry(key).or_insert_with(|| MemberPlan {
        member_id: managed_member_id(workspace_id, "tui", &row.tui_id),
        runtime_kind: row.runtime.clone(),
        managed_agent_kind: Some("tui".to_string()),
        managed_agent_id: Some(row.tui_id.clone()),
        display_name: row.tui_id.clone(),
        role: None,
        membership_status: if is_selected {
            AgentWorkspaceMembershipStatus::PendingRegistration
        } else {
            AgentWorkspaceMembershipStatus::Historical
        },
        liveness_status: AgentWorkspaceLivenessStatus::Unknown,
        runtime_session_id: None,
        assignment_id: None,
        runtime_lifecycle: AgentWorkspaceRuntimeLifecycle::Unavailable,
        runtime_evidence: String::new(),
        source_session_id: Some(row.session_id.clone()),
        source_agent_id: (!row.agent_id.is_empty()).then(|| row.agent_id.clone()),
        source_digest: String::new(),
        membership_source_digest: String::new(),
        runtime_source_digest: String::new(),
        membership_override_source_digest: None,
        runtime_override_source_digest: None,
        joined_at: None,
        last_activity_at: Some(row.updated_at.clone()),
        created_at: row.created_at.clone(),
        updated_at: row.updated_at.clone(),
        provenance: Vec::new(),
    });
    if is_selected || member.runtime_evidence.is_empty() {
        member.runtime_kind.clone_from(&row.runtime);
        member.runtime_lifecycle = tui_lifecycle(row)?;
        member.runtime_evidence = runtime_evidence(
            "tui",
            &row.status,
            row.exit_code.map(|code| code.to_string()).as_deref(),
            row.signal.as_deref(),
            row.error.as_deref(),
        );
        member.last_activity_at = Some(row.updated_at.clone());
        member.updated_at.clone_from(&row.updated_at);
        let digest = tui_digest(row);
        member.runtime_source_digest = tui_operation_marker(row);
        if member.source_digest.is_empty() {
            member.source_digest = digest;
        }
    }
    Ok(())
}

fn merge_codex(
    members: &mut BTreeMap<MemberKey, MemberPlan>,
    workspace_id: &str,
    selected_session_id: &str,
    row: &CodexRow,
) -> Result<(), AgentWorkspaceTeamConflict> {
    let key = MemberKey::Managed {
        kind: "codex".to_string(),
        id: row.run_id.clone(),
    };
    let is_selected = row.session_id == selected_session_id;
    let member = members.entry(key).or_insert_with(|| MemberPlan {
        member_id: managed_member_id(workspace_id, "codex", &row.run_id),
        runtime_kind: "codex".to_string(),
        managed_agent_kind: Some("codex".to_string()),
        managed_agent_id: Some(row.run_id.clone()),
        display_name: row
            .display_name
            .clone()
            .unwrap_or_else(|| row.run_id.clone()),
        role: None,
        membership_status: if is_selected {
            AgentWorkspaceMembershipStatus::PendingRegistration
        } else {
            AgentWorkspaceMembershipStatus::Historical
        },
        liveness_status: AgentWorkspaceLivenessStatus::Unknown,
        runtime_session_id: row.thread_id.clone(),
        assignment_id: row.task_id.clone(),
        runtime_lifecycle: AgentWorkspaceRuntimeLifecycle::Unavailable,
        runtime_evidence: String::new(),
        source_session_id: Some(row.session_id.clone()),
        source_agent_id: row.session_agent_id.clone(),
        source_digest: String::new(),
        membership_source_digest: String::new(),
        runtime_source_digest: String::new(),
        membership_override_source_digest: None,
        runtime_override_source_digest: None,
        joined_at: None,
        last_activity_at: Some(row.updated_at.clone()),
        created_at: row.created_at.clone(),
        updated_at: row.updated_at.clone(),
        provenance: Vec::new(),
    });
    validate_managed_runtime_binding(
        member,
        row.thread_id.as_deref(),
        "codex",
        &row.run_id,
        &row.session_id,
    )?;
    if is_selected || member.runtime_evidence.is_empty() {
        member.runtime_lifecycle = codex_lifecycle(row)?;
        member.runtime_evidence = runtime_evidence(
            "codex",
            &row.status,
            row.thread_id.as_deref(),
            None,
            row.error.as_deref(),
        );
        if member.runtime_session_id.is_none() {
            member.runtime_session_id.clone_from(&row.thread_id);
        }
        if member.assignment_id.is_none() {
            member.assignment_id.clone_from(&row.task_id);
        }
        member.last_activity_at = Some(row.updated_at.clone());
        member.updated_at.clone_from(&row.updated_at);
        let digest = codex_digest(row);
        member.runtime_source_digest = codex_operation_marker(row);
        if member.source_digest.is_empty() {
            member.source_digest = digest;
        }
    }
    Ok(())
}

fn leader_member_id(
    members: &[MemberPlan],
    selected_session_id: &str,
    selected_lifecycle: &str,
    leader_agent_id: Option<&str>,
) -> Option<String> {
    if selected_lifecycle != "active" {
        return None;
    }
    let leader_agent_id = leader_agent_id?;
    members.iter().find_map(|member| {
        member
            .provenance
            .iter()
            .any(|source| {
                source.is_selected
                    && source.source_session_id == selected_session_id
                    && source.source_agent_id == leader_agent_id
            })
            .then(|| member.member_id.clone())
    })
}

fn liveness_status(value: &str) -> AgentWorkspaceLivenessStatus {
    let label = serde_json::from_str::<Value>(value)
        .ok()
        .and_then(|value| match value {
            Value::String(label) => Some(label),
            Value::Object(fields) => fields
                .get("state")
                .and_then(Value::as_str)
                .map(str::to_string),
            _ => None,
        })
        .unwrap_or_else(|| value.to_string());
    match label.as_str() {
        "active" => AgentWorkspaceLivenessStatus::Active,
        "idle" => AgentWorkspaceLivenessStatus::Idle,
        "awaiting_review" => AgentWorkspaceLivenessStatus::AwaitingReview,
        "disconnected" => AgentWorkspaceLivenessStatus::Disconnected,
        "removed" => AgentWorkspaceLivenessStatus::Removed,
        _ => AgentWorkspaceLivenessStatus::Unknown,
    }
}

fn tui_lifecycle(
    row: &TuiRow,
) -> Result<AgentWorkspaceRuntimeLifecycle, AgentWorkspaceTeamConflict> {
    match row.status.as_str() {
        "starting" | "running" => Ok(AgentWorkspaceRuntimeLifecycle::Recoverable),
        "exited" | "stopped" => Ok(AgentWorkspaceRuntimeLifecycle::Completed),
        "failed" => Ok(AgentWorkspaceRuntimeLifecycle::Failed),
        _ => Err(malformed_conflict(
            vec![row.session_id.clone()],
            format!("terminal runtime has unknown status '{}'", row.status),
        )),
    }
}

fn codex_lifecycle(
    row: &CodexRow,
) -> Result<AgentWorkspaceRuntimeLifecycle, AgentWorkspaceTeamConflict> {
    match row.status.as_str() {
        "queued" | "running" | "waiting_approval" => {
            Ok(AgentWorkspaceRuntimeLifecycle::Recoverable)
        }
        "completed" | "cancelled" => Ok(AgentWorkspaceRuntimeLifecycle::Completed),
        "failed" => Ok(AgentWorkspaceRuntimeLifecycle::Failed),
        _ => Err(malformed_conflict(
            vec![row.session_id.clone()],
            format!("Codex runtime has unknown status '{}'", row.status),
        )),
    }
}
