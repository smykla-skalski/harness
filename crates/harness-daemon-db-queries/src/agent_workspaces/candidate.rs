use chrono::{DateTime, Utc};
use harness_protocol::daemon::summaries::AgentWorkspaceAvailability;
use harness_protocol::session::{AgentStatus, CURRENT_VERSION, SessionState, TaskStatus};
use std::cmp::Ordering;

use super::availability::{RecordedCheckout, recorded_checkout_availability};
use super::identity::digest_fields;
use super::source::LegacyCandidateRow;

#[derive(Debug)]
pub(super) struct Candidate {
    pub session_id: String,
    pub lifecycle: Lifecycle,
    pub availability: AgentWorkspaceAvailability,
    pub liveness_evidence: String,
    pub effective_activity_at: Option<String>,
    pub updated_at: String,
    pub created_at: String,
    pub source_digest: String,
    effective_activity_instant: Option<DateTime<Utc>>,
    updated_at_instant: DateTime<Utc>,
    created_at_instant: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Lifecycle {
    Active,
    Stale,
    Ended,
}

impl Lifecycle {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Stale => "stale",
            Self::Ended => "ended",
        }
    }

    const fn rank(self) -> u8 {
        match self {
            Self::Active => 2,
            Self::Stale => 1,
            Self::Ended => 0,
        }
    }
}

pub(super) fn classify_candidate(row: &LegacyCandidateRow) -> Result<Candidate, String> {
    if !matches!(row.is_worktree, 0 | 1) {
        return Err(format!(
            "Session {} has noncanonical worktree state {}",
            row.session_id, row.is_worktree
        ));
    }
    let state = parse_and_validate_state(row)?;
    validate_normalized_liveness(row, &state)?;
    let evidence = liveness_evidence(row);
    let lifecycle = classify_lifecycle(row, &evidence)?;
    let mut activity_values = vec![
        Some(row.updated_at.as_str()),
        row.last_activity_at.as_deref(),
    ];
    activity_values.extend(
        row.activity_timestamps
            .iter()
            .map(|activity| Some(activity.recorded_at.as_str())),
    );
    let effective_activity_instant = latest_timestamp(&activity_values, &row.session_id)?;
    let updated_at_instant = parse_timestamp(&row.updated_at, &row.session_id)?;
    let created_at_instant = parse_timestamp(&row.created_at, &row.session_id)?;
    parse_timestamp(&row.project_updated_at, &row.session_id)?;
    let availability = recorded_checkout_availability(RecordedCheckout {
        project_dir: row.project_dir.as_deref(),
        repository_root: row.repository_root.as_deref(),
        is_worktree: row.is_worktree == 1,
        worktree_name: row.worktree_name.as_deref(),
    })
    .map_err(|detail| format!("Session {} checkout is invalid: {detail}", row.session_id))?;
    let effective_activity_at = effective_activity_instant.map(|value| value.to_rfc3339());
    let source_digest = candidate_source_digest(
        row,
        availability,
        effective_activity_at.as_deref(),
        &evidence,
    );
    Ok(Candidate {
        session_id: row.session_id.clone(),
        lifecycle,
        availability,
        liveness_evidence: evidence.join(", "),
        effective_activity_at,
        updated_at: row.updated_at.clone(),
        created_at: row.created_at.clone(),
        source_digest,
        effective_activity_instant,
        updated_at_instant,
        created_at_instant,
    })
}

fn parse_and_validate_state(row: &LegacyCandidateRow) -> Result<SessionState, String> {
    let state: SessionState = serde_json::from_str(&row.state_json)
        .map_err(|error| format!("Session {} state is unreadable: {error}", row.session_id))?;
    if state.session_id != row.session_id {
        return Err(format!(
            "Session {} state names Session {}",
            row.session_id, state.session_id
        ));
    }
    if state.schema_version != CURRENT_VERSION
        || i64::from(state.schema_version) != row.schema_version
    {
        return Err(format!(
            "Session {} has unsupported or inconsistent schema version",
            row.session_id
        ));
    }
    if row.state_version < 0 {
        return Err(format!(
            "Session {} has a negative revision",
            row.session_id
        ));
    }
    if state.state_version != u64::try_from(row.state_version).unwrap_or(u64::MAX)
        || state.created_at != row.created_at
        || state.updated_at != row.updated_at
        || state.last_activity_at != row.last_activity_at
    {
        return Err(format!(
            "Session {} row disagrees with its state document",
            row.session_id
        ));
    }
    let state_status = serde_json::to_value(state.status)
        .ok()
        .and_then(|value| value.as_str().map(ToString::to_string));
    if state_status.as_deref() != Some(row.status.as_str()) {
        return Err(format!(
            "Session {} status disagrees with its state document",
            row.session_id
        ));
    }
    Ok(state)
}

fn validate_normalized_liveness(
    row: &LegacyCandidateRow,
    state: &SessionState,
) -> Result<(), String> {
    let state_has_live_agent = state.agents.values().any(|agent| {
        matches!(
            agent.status,
            AgentStatus::Active | AgentStatus::Idle | AgentStatus::AwaitingReview
        )
    });
    let state_has_review_obligation = state.tasks.values().any(|task| {
        matches!(
            task.status,
            TaskStatus::AwaitingReview | TaskStatus::InReview
        )
    });
    if state_has_live_agent != (row.has_live_agent != 0)
        || state_has_review_obligation != (row.has_review_obligation != 0)
    {
        return Err(format!(
            "Session {} normalized rows disagree with its state document",
            row.session_id
        ));
    }
    Ok(())
}

fn classify_lifecycle(
    row: &LegacyCandidateRow,
    evidence: &[&'static str],
) -> Result<Lifecycle, String> {
    let has_live_work = !evidence.is_empty();
    match (row.status.as_str(), has_live_work) {
        ("ended", false) => Ok(Lifecycle::Ended),
        ("ended", true) => Err(format!(
            "ended Session {} still carries live work: {}",
            row.session_id,
            evidence.join(", ")
        )),
        ("awaiting_leader" | "active" | "paused" | "leaderless_degraded", true) => {
            Ok(Lifecycle::Active)
        }
        ("awaiting_leader" | "active" | "paused" | "leaderless_degraded", false) => {
            Ok(Lifecycle::Stale)
        }
        (status, _) => Err(format!(
            "Session {} has unknown status {status}",
            row.session_id
        )),
    }
}

fn candidate_source_digest(
    row: &LegacyCandidateRow,
    availability: AgentWorkspaceAvailability,
    effective_activity_at: Option<&str>,
    evidence: &[&'static str],
) -> String {
    let state_version = row.state_version.to_string();
    let evidence_text = evidence.join("\n");
    let schema_version = row.schema_version.to_string();
    let is_worktree = row.is_worktree.to_string();
    let activity_digest = digest_fields(
        row.activity_timestamps
            .iter()
            .flat_map(|activity| [activity.source.as_str(), activity.recorded_at.as_str()]),
    );
    digest_fields([
        row.session_id.as_str(),
        row.source_project_id.as_str(),
        schema_version.as_str(),
        state_version.as_str(),
        row.status.as_str(),
        row.created_at.as_str(),
        row.updated_at.as_str(),
        row.last_activity_at.as_deref().unwrap_or(""),
        activity_digest.as_str(),
        row.project_updated_at.as_str(),
        row.project_name.as_str(),
        row.project_dir.as_deref().unwrap_or(""),
        row.repository_root.as_deref().unwrap_or(""),
        row.context_root.as_str(),
        row.checkout_id.as_str(),
        row.checkout_name.as_str(),
        is_worktree.as_str(),
        row.worktree_name.as_deref().unwrap_or(""),
        availability_label(availability),
        effective_activity_at.unwrap_or(""),
        row.state_json.as_str(),
        evidence_text.as_str(),
    ])
}

const fn availability_label(availability: AgentWorkspaceAvailability) -> &'static str {
    match availability {
        AgentWorkspaceAvailability::Available => "available",
        AgentWorkspaceAvailability::MissingWorktree => "missing_worktree",
    }
}

fn liveness_evidence(row: &LegacyCandidateRow) -> Vec<&'static str> {
    [
        (row.has_live_agent != 0, "live agent"),
        (row.has_live_tui != 0, "managed terminal"),
        (row.has_live_codex_run != 0, "Codex run"),
        (row.has_live_turn != 0, "managed turn"),
        (row.has_pending_signal != 0, "pending signal"),
        (row.has_review_obligation != 0, "review obligation"),
    ]
    .into_iter()
    .filter_map(|(present, label)| present.then_some(label))
    .collect()
}

fn latest_timestamp(
    values: &[Option<&str>],
    session_id: &str,
) -> Result<Option<DateTime<Utc>>, String> {
    values.iter().flatten().try_fold(None, |latest, value| {
        let parsed = parse_timestamp(value, session_id)?;
        Ok(Some(
            latest.map_or(parsed, |prior: DateTime<Utc>| prior.max(parsed)),
        ))
    })
}

fn parse_timestamp(value: &str, session_id: &str) -> Result<DateTime<Utc>, String> {
    DateTime::parse_from_rfc3339(value)
        .map(|timestamp| timestamp.with_timezone(&Utc))
        .map_err(|error| format!("Session {session_id} has invalid timestamp {value}: {error}"))
}

pub(super) fn compare_candidates(left: &Candidate, right: &Candidate) -> Ordering {
    left.lifecycle
        .rank()
        .cmp(&right.lifecycle.rank())
        .then_with(|| {
            left.effective_activity_instant
                .cmp(&right.effective_activity_instant)
        })
        .then_with(|| left.updated_at_instant.cmp(&right.updated_at_instant))
        .then_with(|| left.created_at_instant.cmp(&right.created_at_instant))
        .then_with(|| left.session_id.as_bytes().cmp(right.session_id.as_bytes()))
}
