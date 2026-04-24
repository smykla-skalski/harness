use crate::session::types::WorkItem;

#[cfg(test)]
mod tests {
    use super::TaskRowBindings;
    use crate::session::types::{
        AwaitingReview, ReviewClaim, ReviewConsensus, ReviewVerdict, ReviewerEntry,
        TaskQueuePolicy, TaskSeverity, TaskSource, TaskStatus, WorkItem,
    };

    fn base_task() -> WorkItem {
        WorkItem {
            task_id: "t-1".to_string(),
            title: "title".to_string(),
            context: None,
            severity: TaskSeverity::Medium,
            status: TaskStatus::Open,
            assigned_to: None,
            queue_policy: TaskQueuePolicy::default(),
            queued_at: None,
            created_at: "2026-04-24T00:00:00Z".to_string(),
            updated_at: "2026-04-24T00:00:00Z".to_string(),
            created_by: None,
            notes: Vec::new(),
            suggested_fix: None,
            source: TaskSource::Manual,
            observe_issue_id: None,
            blocked_reason: None,
            completed_at: None,
            checkpoint_summary: None,
            awaiting_review: None,
            review_claim: None,
            consensus: None,
            review_history: Vec::new(),
            review_round: 0,
            arbitration: None,
            suggested_persona: None,
        }
    }

    #[test]
    fn default_task_yields_none_review_bindings_and_default_consensus() {
        let row = TaskRowBindings::from_task(&base_task());
        assert!(row.review_claim_json.is_none());
        assert!(row.consensus_json.is_none());
        assert!(row.arbitration_json.is_none());
        assert!(row.awaiting_queued_at.is_none());
        assert!(row.awaiting_submitter.is_none());
        assert_eq!(row.awaiting_required_consensus, 2);
        assert_eq!(row.review_round, 0);
    }

    #[test]
    fn awaiting_review_and_claim_serialize_into_v10_columns() {
        let mut task = base_task();
        task.awaiting_review = Some(AwaitingReview {
            queued_at: "2026-04-24T12:00:00Z".to_string(),
            submitter_agent_id: "worker-1".to_string(),
            summary: Some("ready".to_string()),
            required_consensus: 3,
        });
        task.review_claim = Some(ReviewClaim {
            reviewers: vec![ReviewerEntry {
                reviewer_agent_id: "rev-1".to_string(),
                reviewer_runtime: "gemini".to_string(),
                claimed_at: "2026-04-24T12:01:00Z".to_string(),
                submitted_at: None,
            }],
        });
        task.review_round = 2;
        task.suggested_persona = Some("code-reviewer".to_string());

        let row = TaskRowBindings::from_task(&task);
        assert_eq!(
            row.awaiting_queued_at.as_deref(),
            Some("2026-04-24T12:00:00Z")
        );
        assert_eq!(row.awaiting_submitter.as_deref(), Some("worker-1"));
        assert_eq!(row.awaiting_required_consensus, 3);
        assert_eq!(row.review_round, 2);
        let claim_json = row.review_claim_json.expect("review_claim serialized");
        assert!(claim_json.contains("\"reviewer_agent_id\":\"rev-1\""));
    }

    #[test]
    fn consensus_and_arbitration_round_trip_into_columns() {
        let mut task = base_task();
        task.consensus = Some(ReviewConsensus {
            verdict: ReviewVerdict::Approve,
            summary: "lgtm".to_string(),
            points: Vec::new(),
            closed_at: "2026-04-24T12:05:00Z".to_string(),
            reviewer_agent_ids: vec!["rev-1".to_string()],
        });
        let row = TaskRowBindings::from_task(&task);
        let consensus_json = row.consensus_json.expect("consensus serialized");
        assert!(consensus_json.contains("\"verdict\":\"approve\""));
    }
}

/// Precomputed bindings for a single row in the `tasks` table. Shared by
/// the sync (rusqlite) and async (sqlx) task mirror writers so v10 columns
/// stay in lock-step and the two paths cannot diverge silently.
pub(super) struct TaskRowBindings {
    pub severity: String,
    pub status: String,
    pub source: String,
    pub notes_json: String,
    pub checkpoint_summary_json: Option<String>,
    pub review_claim_json: Option<String>,
    pub consensus_json: Option<String>,
    pub arbitration_json: Option<String>,
    pub awaiting_queued_at: Option<String>,
    pub awaiting_submitter: Option<String>,
    pub awaiting_required_consensus: i64,
    pub review_round: i64,
}

impl TaskRowBindings {
    pub(super) fn from_task(task: &WorkItem) -> Self {
        let notes_json = serde_json::to_string(&task.notes).unwrap_or_default();
        let checkpoint_summary_json = task
            .checkpoint_summary
            .as_ref()
            .and_then(|summary| serde_json::to_string(summary).ok());
        let review_claim_json = task
            .review_claim
            .as_ref()
            .and_then(|claim| serde_json::to_string(claim).ok());
        let consensus_json = task
            .consensus
            .as_ref()
            .and_then(|consensus| serde_json::to_string(consensus).ok());
        let arbitration_json = task
            .arbitration
            .as_ref()
            .and_then(|outcome| serde_json::to_string(outcome).ok());
        let awaiting_queued_at = task.awaiting_review.as_ref().map(|a| a.queued_at.clone());
        let awaiting_submitter = task
            .awaiting_review
            .as_ref()
            .map(|a| a.submitter_agent_id.clone());
        let awaiting_required_consensus = task
            .awaiting_review
            .as_ref()
            .map_or(2_i64, |a| i64::from(a.required_consensus));

        Self {
            severity: format!("{:?}", task.severity).to_lowercase(),
            status: format!("{:?}", task.status).to_lowercase(),
            source: format!("{:?}", task.source).to_lowercase(),
            notes_json,
            checkpoint_summary_json,
            review_claim_json,
            consensus_json,
            arbitration_json,
            awaiting_queued_at,
            awaiting_submitter,
            awaiting_required_consensus,
            review_round: i64::from(task.review_round),
        }
    }
}
