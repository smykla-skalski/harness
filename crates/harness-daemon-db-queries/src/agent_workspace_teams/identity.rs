use sha2::{Digest, Sha256};

use super::model::{MemberPlan, MemberProvenancePlan, TeamPlan};

pub(super) fn managed_member_id(workspace_id: &str, kind: &str, id: &str) -> String {
    let _ = workspace_id;
    format!("member-m-{}-{}", hex::encode(kind), hex::encode(id))
}

pub(super) fn legacy_member_id(workspace_id: &str, session_id: &str, agent_id: &str) -> String {
    let _ = workspace_id;
    format!(
        "member-l-{}-{}",
        hex::encode(session_id),
        hex::encode(agent_id)
    )
}

pub(super) fn digest_fields<'a>(fields: impl IntoIterator<Item = &'a str>) -> String {
    let mut hasher = Sha256::new();
    for field in fields {
        hasher.update(field.len().to_be_bytes());
        hasher.update(field.as_bytes());
    }
    hex::encode(hasher.finalize())
}

pub(super) fn member_source_digest(fields: &[&str]) -> String {
    digest_fields(fields.iter().copied())
}

pub(super) fn team_shadow_digest(plan: &TeamPlan, created_at: &str) -> String {
    let mut fields = vec![
        "1",
        plan.workspace_id.as_str(),
        plan.authority.as_str(),
        plan.selected_legacy_session_id
            .as_deref()
            .unwrap_or_default(),
        plan.selected_lifecycle.as_deref().unwrap_or_default(),
        plan.leader_member_id.as_deref().unwrap_or_default(),
        created_at,
    ];
    for member in &plan.members {
        push_member_fields(&mut fields, member);
    }
    digest_fields(fields)
}

fn push_member_fields<'a>(fields: &mut Vec<&'a str>, member: &'a MemberPlan) {
    fields.extend([
        member.member_id.as_str(),
        member.runtime_kind.as_str(),
        member.managed_agent_kind.as_deref().unwrap_or_default(),
        member.managed_agent_id.as_deref().unwrap_or_default(),
        member.display_name.as_str(),
        member.role.as_deref().unwrap_or_default(),
        membership_label(member),
        liveness_label(member),
        member.runtime_session_id.as_deref().unwrap_or_default(),
        member.assignment_id.as_deref().unwrap_or_default(),
        runtime_lifecycle_label(member),
        member.runtime_evidence.as_str(),
        member.source_session_id.as_deref().unwrap_or_default(),
        member.source_agent_id.as_deref().unwrap_or_default(),
        member.source_digest.as_str(),
        member.membership_source_digest.as_str(),
        member.runtime_source_digest.as_str(),
        member
            .membership_override_source_digest
            .as_deref()
            .unwrap_or_default(),
        member
            .runtime_override_source_digest
            .as_deref()
            .unwrap_or_default(),
        member.joined_at.as_deref().unwrap_or_default(),
        member.last_activity_at.as_deref().unwrap_or_default(),
        member.created_at.as_str(),
        member.updated_at.as_str(),
    ]);
    for provenance in &member.provenance {
        push_provenance_fields(fields, provenance);
    }
}

fn push_provenance_fields<'a>(fields: &mut Vec<&'a str>, provenance: &'a MemberProvenancePlan) {
    fields.extend([
        provenance.source_session_id.as_str(),
        provenance.source_agent_id.as_str(),
        provenance.source_digest.as_str(),
        if provenance.is_selected { "1" } else { "0" },
    ]);
}

const fn membership_label(member: &MemberPlan) -> &'static str {
    use harness_protocol::daemon::summaries::AgentWorkspaceMembershipStatus as Status;
    match member.membership_status {
        Status::PendingRegistration => "pending_registration",
        Status::Joined => "joined",
        Status::Removed => "removed",
        Status::Historical => "historical",
    }
}

const fn liveness_label(member: &MemberPlan) -> &'static str {
    use harness_protocol::daemon::summaries::AgentWorkspaceLivenessStatus as Status;
    match member.liveness_status {
        Status::Active => "active",
        Status::Idle => "idle",
        Status::AwaitingReview => "awaiting_review",
        Status::Disconnected => "disconnected",
        Status::Removed => "removed",
        Status::Unknown => "unknown",
    }
}

const fn runtime_lifecycle_label(member: &MemberPlan) -> &'static str {
    use harness_protocol::daemon::summaries::AgentWorkspaceRuntimeLifecycle as Status;
    match member.runtime_lifecycle {
        Status::Running => "running",
        Status::Recoverable => "recoverable",
        Status::Completed => "completed",
        Status::Failed => "failed",
        Status::Unavailable => "unavailable",
    }
}
