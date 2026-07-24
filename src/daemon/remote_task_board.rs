use serde::Serialize;

use crate::daemon::protocol::{
    TaskBoardItemPositionSnapshot, TaskBoardListItemsResponse, TaskBoardTriageCurrentResponse,
    TaskBoardTriageHistoryResponse,
};
use crate::task_board::{
    AgentMode, TaskBoardItem, TaskBoardPriority, TaskBoardStatus, TaskBoardTriageDecisionRecord,
    TaskBoardTriageOverride,
};

use super::remote_redaction::{REDACTION_PLACEHOLDER, redact_known_secrets};

const BODY_PREVIEW_CHAR_LIMIT: usize = 180;
const BODY_PREVIEW_PREFIX_LIMIT: usize = BODY_PREVIEW_CHAR_LIMIT - 3;

#[derive(Serialize)]
#[serde(untagged)]
pub(crate) enum TaskBoardReadItemResponse {
    Full(Box<TaskBoardItem>),
    Viewer(Box<RemoteViewerTaskBoardItem>),
}

#[derive(Serialize)]
#[serde(untagged)]
pub(crate) enum TaskBoardReadListResponse {
    Full(TaskBoardListItemsResponse),
    Viewer(RemoteViewerTaskBoardListResponse),
}

#[derive(Serialize)]
#[serde(untagged)]
pub(crate) enum TaskBoardPositionSnapshotResponse {
    Full(Box<TaskBoardItemPositionSnapshot>),
    Viewer(Box<RemoteViewerTaskBoardPositionSnapshot>),
}

#[derive(Serialize)]
pub(crate) struct RemoteViewerTaskBoardListResponse {
    items: Vec<RemoteViewerTaskBoardItem>,
    items_change_seq: i64,
    item_revisions: std::collections::HashMap<String, i64>,
}

#[derive(Serialize)]
pub(crate) struct RemoteViewerTaskBoardItem {
    schema_version: u32,
    id: String,
    title: String,
    body: String,
    status: TaskBoardStatus,
    priority: TaskBoardPriority,
    #[serde(skip_serializing_if = "Option::is_none")]
    lane_position: Option<u32>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    project_id: Option<String>,
    agent_mode: AgentMode,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    work_item_id: Option<String>,
    created_at: String,
    updated_at: String,
}

#[derive(Serialize)]
pub(crate) struct RemoteViewerTaskBoardPositionSnapshot {
    item: RemoteViewerTaskBoardItem,
    item_revision: i64,
    items_change_seq: i64,
}

#[must_use]
pub(crate) fn project_task_board_list(
    response: TaskBoardListItemsResponse,
    viewer: bool,
) -> TaskBoardReadListResponse {
    if viewer {
        let TaskBoardListItemsResponse {
            items,
            items_change_seq,
            item_revisions,
            ..
        } = response;
        TaskBoardReadListResponse::Viewer(RemoteViewerTaskBoardListResponse {
            items: items
                .into_iter()
                .map(RemoteViewerTaskBoardItem::from)
                .collect(),
            items_change_seq,
            item_revisions,
        })
    } else {
        TaskBoardReadListResponse::Full(response)
    }
}

#[must_use]
pub(crate) fn project_task_board_item(
    item: TaskBoardItem,
    viewer: bool,
) -> TaskBoardReadItemResponse {
    if viewer {
        TaskBoardReadItemResponse::Viewer(Box::new(item.into()))
    } else {
        TaskBoardReadItemResponse::Full(Box::new(item))
    }
}

#[must_use]
pub(crate) fn project_task_board_position_snapshot(
    snapshot: TaskBoardItemPositionSnapshot,
    viewer: bool,
) -> TaskBoardPositionSnapshotResponse {
    if viewer {
        TaskBoardPositionSnapshotResponse::Viewer(Box::new(RemoteViewerTaskBoardPositionSnapshot {
            item: snapshot.item.into(),
            item_revision: snapshot.item_revision,
            items_change_seq: snapshot.items_change_seq,
        }))
    } else {
        TaskBoardPositionSnapshotResponse::Full(Box::new(snapshot))
    }
}

/// Triage redaction nulls `reason_detail`/`evidence_fingerprint` on the same
/// record type rather than projecting to a distinct viewer struct: unlike the
/// item/position projections above, every other field is already safe to show
/// a remote viewer as-is, so a second mirrored type would only double the
/// generated Swift surface for no redaction benefit.
#[must_use]
pub(crate) fn project_task_board_triage_current(
    response: TaskBoardTriageCurrentResponse,
    viewer: bool,
) -> TaskBoardTriageCurrentResponse {
    if viewer {
        TaskBoardTriageCurrentResponse {
            current: response.current.map(redact_triage_record),
            triage_override: response.triage_override.map(redact_triage_override),
            effective: response.effective,
        }
    } else {
        response
    }
}

#[must_use]
pub(crate) fn project_task_board_triage_history(
    response: TaskBoardTriageHistoryResponse,
    viewer: bool,
) -> TaskBoardTriageHistoryResponse {
    if viewer {
        TaskBoardTriageHistoryResponse {
            decisions: response
                .decisions
                .into_iter()
                .map(redact_triage_record)
                .collect(),
            next_before_generation: response.next_before_generation,
        }
    } else {
        response
    }
}

fn redact_triage_record(record: TaskBoardTriageDecisionRecord) -> TaskBoardTriageDecisionRecord {
    TaskBoardTriageDecisionRecord {
        reason_detail: None,
        evidence_fingerprint: None,
        ..record
    }
}

/// A remote viewer may see that a triage override is active plus its verdict
/// and `set_at` timestamp, but the setting actor and any free-text reason are
/// sensitive and must be redacted.
fn redact_triage_override(override_: TaskBoardTriageOverride) -> TaskBoardTriageOverride {
    TaskBoardTriageOverride {
        actor: REDACTION_PLACEHOLDER.to_string(),
        reason: None,
        ..override_
    }
}

impl From<TaskBoardItem> for RemoteViewerTaskBoardItem {
    fn from(item: TaskBoardItem) -> Self {
        Self {
            schema_version: item.schema_version,
            id: item.id,
            title: redact_known_secrets(&item.title),
            body: body_preview(&item.body),
            status: item.status,
            priority: item.priority,
            lane_position: item.lane_position,
            tags: item
                .tags
                .into_iter()
                .map(|tag| redact_known_secrets(&tag))
                .collect(),
            project_id: item
                .project_id
                .map(|project_id| redact_known_secrets(&project_id)),
            agent_mode: item.agent_mode,
            session_id: item.session_id,
            work_item_id: item.work_item_id,
            created_at: item.created_at,
            updated_at: item.updated_at,
        }
    }
}

fn body_preview(body: &str) -> String {
    let redacted = redact_known_secrets(body.trim());
    let mut chars = redacted.chars();
    let prefix = chars
        .by_ref()
        .take(BODY_PREVIEW_CHAR_LIMIT)
        .collect::<String>();
    if chars.next().is_none() {
        return prefix;
    }
    let mut preview = prefix
        .chars()
        .take(BODY_PREVIEW_PREFIX_LIMIT)
        .collect::<String>();
    preview.push_str("...");
    preview
}

#[cfg(test)]
mod tests {
    use super::{
        TaskBoardTriageCurrentResponse, TaskBoardTriageHistoryResponse, body_preview,
        project_task_board_triage_current, project_task_board_triage_history,
    };
    use crate::task_board::{
        TaskBoardTriageDecisionRecord, TaskBoardTriageOverride, TriageCause, TriageReasonCode,
        TriageVerdict, is_canonical_override_actor,
    };

    fn sample_override() -> TaskBoardTriageOverride {
        TaskBoardTriageOverride {
            verdict: TriageVerdict::Undecided,
            actor: "operator-1".to_string(),
            reason: Some("looks fine as backlog".to_string()),
            set_at: "2026-07-23T00:00:00Z".to_string(),
        }
    }

    fn sample_record() -> TaskBoardTriageDecisionRecord {
        TaskBoardTriageDecisionRecord {
            decision_id: "triage-00000000000000000000000000000000".to_string(),
            item_id: "task-1".to_string(),
            generation: 1,
            verdict: TriageVerdict::Todo,
            reason_code: TriageReasonCode::MeaningfulLabel,
            reason_detail: Some("secret detail".to_string()),
            evaluator_identity: "task_board.triage.builtin_v1".to_string(),
            evaluator_version: 1,
            evidence_fingerprint: Some(
                "sha256:0000000000000000000000000000000000000000000000000000000000000000"
                    .to_string(),
            ),
            cause: TriageCause::Initial,
            decided_at: "2026-07-23T00:00:00Z".to_string(),
            superseded_at: None,
        }
    }

    #[test]
    fn viewer_current_nulls_reason_detail_and_evidence_fingerprint() {
        let response = TaskBoardTriageCurrentResponse {
            current: Some(sample_record()),
            triage_override: None,
            effective: None,
        };
        let projected = project_task_board_triage_current(response, true);
        let wire = serde_json::to_value(&projected).expect("serialize viewer projection");
        assert!(wire["current"]["reason_detail"].is_null());
        assert!(wire["current"]["evidence_fingerprint"].is_null());
        let current = projected.current.expect("current decision");
        assert!(current.reason_detail.is_none());
        assert!(current.evidence_fingerprint.is_none());
        assert_eq!(
            current.decision_id,
            "triage-00000000000000000000000000000000"
        );
    }

    #[test]
    fn full_current_keeps_reason_detail_and_evidence_fingerprint() {
        let response = TaskBoardTriageCurrentResponse {
            current: Some(sample_record()),
            triage_override: None,
            effective: None,
        };
        let projected = project_task_board_triage_current(response, false);
        let current = projected.current.expect("current decision");
        assert_eq!(current.reason_detail.as_deref(), Some("secret detail"));
        assert_eq!(
            current.evidence_fingerprint.as_deref(),
            Some("sha256:0000000000000000000000000000000000000000000000000000000000000000")
        );
    }

    #[test]
    fn viewer_current_redacts_override_actor_and_reason_but_keeps_verdict_and_timestamp() {
        let response = TaskBoardTriageCurrentResponse {
            current: None,
            triage_override: Some(sample_override()),
            effective: None,
        };
        let projected = project_task_board_triage_current(response, true);
        let wire = serde_json::to_value(&projected).expect("serialize viewer projection");
        assert_eq!(wire["triage_override"]["actor"], "[redacted]");
        assert!(wire["triage_override"]["reason"].is_null());
        assert_eq!(wire["triage_override"]["verdict"], "undecided");
        assert_eq!(wire["triage_override"]["set_at"], "2026-07-23T00:00:00Z");
        let triage_override = projected.triage_override.expect("override");
        assert!(
            is_canonical_override_actor(&triage_override.actor),
            "a redacted actor must still be a canonical, valid domain value"
        );
        assert_eq!(triage_override.actor, "[redacted]");
        assert!(triage_override.reason.is_none());
    }

    #[test]
    fn full_current_keeps_override_actor_and_reason() {
        let response = TaskBoardTriageCurrentResponse {
            current: None,
            triage_override: Some(sample_override()),
            effective: None,
        };
        let projected = project_task_board_triage_current(response, false);
        let triage_override = projected.triage_override.expect("override");
        assert_eq!(triage_override.actor, "operator-1");
        assert_eq!(
            triage_override.reason.as_deref(),
            Some("looks fine as backlog")
        );
    }

    #[test]
    fn viewer_history_nulls_every_decision() {
        let response = TaskBoardTriageHistoryResponse {
            decisions: vec![sample_record(), sample_record()],
            next_before_generation: Some(1),
        };
        let projected = project_task_board_triage_history(response, true);
        assert_eq!(projected.decisions.len(), 2);
        assert!(
            projected
                .decisions
                .iter()
                .all(|decision| decision.reason_detail.is_none()
                    && decision.evidence_fingerprint.is_none())
        );
        assert_eq!(projected.next_before_generation, Some(1));
    }

    #[test]
    fn viewer_body_preview_redacts_then_truncates_by_character() {
        let body = format!("Bearer abcdefghijklmnop {}", "\u{017c}".repeat(200));
        let preview = body_preview(&body);

        assert_eq!(preview.chars().count(), 180);
        assert!(preview.starts_with("Bearer [redacted]"));
        assert!(preview.ends_with("..."));
        assert!(!preview.contains("abcdefghijklmnop"));
    }

    #[test]
    fn viewer_body_preview_keeps_180_characters_and_truncates_181() {
        let exact = "x".repeat(180);
        assert_eq!(body_preview(&exact), exact);
        assert_eq!(
            body_preview(&"x".repeat(181)),
            format!("{}...", "x".repeat(177))
        );
    }
}
