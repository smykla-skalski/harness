use serde::{Deserialize, Deserializer, Serialize, de};

use crate::task_board::{
    TaskBoardTriageDecisionRecord, TaskBoardTriageEffectiveOutcome, TaskBoardTriageOverride,
    TriageVerdict,
};

use super::{TaskBoardItemPositionSnapshot, TaskBoardShiftedItemRevision};

/// Applied when a history request omits `limit`.
pub const TASK_BOARD_TRIAGE_HISTORY_DEFAULT_LIMIT: u32 = 50;
/// Mirrors the DB-layer bound (`TASK_BOARD_TRIAGE_HISTORY_MAX_LIMIT` in
/// `src/daemon/db/task_board/triage_queries.rs`); duplicated here because that
/// module is private to `db::task_board` and the DB layer validates again regardless.
pub const TASK_BOARD_TRIAGE_HISTORY_MAX_LIMIT: u32 = 100;
pub const TASK_BOARD_TRIAGE_HISTORY_INVALID_PARAMS: &str =
    "invalid task-board triage history params";

/// Response for `GET /v1/task-board/items/{item_id}/triage`. Extended with
/// the active override (if any) and the single effective outcome those two
/// resolve to; existing readers that only look at `current` are unaffected.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardTriageCurrentResponse {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current: Option<TaskBoardTriageDecisionRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub triage_override: Option<TaskBoardTriageOverride>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effective: Option<TaskBoardTriageEffectiveOutcome>,
}

/// Request for `PUT /v1/task-board/items/{item_id}/triage/override`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardSetTriageOverrideRequest {
    pub verdict: TriageVerdict,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub expected_item_revision: i64,
    pub expected_items_change_seq: i64,
    /// Bound to the authenticated control-plane principal at the transport edge.
    #[serde(default)]
    pub actor: String,
}

/// Request for `POST /v1/task-board/items/{item_id}/triage/override/clear`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardClearTriageOverrideRequest {
    pub expected_item_revision: i64,
    pub expected_items_change_seq: i64,
    /// Bound to the authenticated control-plane principal at the transport edge.
    #[serde(default)]
    pub actor: String,
}

/// Result of a triage override set or clear under one item-revision and
/// item-list sequence CAS. Mirrors [`TaskBoardItemPositionMutationResponse`]'s
/// snapshot/shifted shape so a client can update lane placement from the
/// mutation response alone.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardTriageOverrideMutationResponse {
    pub snapshot: TaskBoardItemPositionSnapshot,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub shifted: Vec<TaskBoardShiftedItemRevision>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub triage_override: Option<TaskBoardTriageOverride>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effective: Option<TaskBoardTriageEffectiveOutcome>,
}

/// Combined WS params for `task_board.triage_history`: the item id plus the
/// same cursor/limit fields the HTTP query string carries. HTTP handlers build
/// this from a path segment and a separate query struct instead of deserializing
/// it directly.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardTriageHistoryRequest {
    pub id: String,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "deserialize_optional_u64"
    )]
    pub before_generation: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

fn deserialize_optional_u64<'de, D>(deserializer: D) -> Result<Option<u64>, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum U64WireValue {
        Number(u64),
        String(String),
    }

    match Option::<U64WireValue>::deserialize(deserializer)? {
        Some(U64WireValue::Number(value)) => Ok(Some(value)),
        Some(U64WireValue::String(value)) => value.parse().map(Some).map_err(de::Error::custom),
        None => Ok(None),
    }
}

impl TaskBoardTriageHistoryRequest {
    #[must_use]
    pub fn validated_page(&self) -> Option<(Option<u64>, u32)> {
        if self
            .before_generation
            .is_some_and(|generation| generation == 0 || generation > i64::MAX.unsigned_abs())
        {
            return None;
        }
        let limit = match self.limit {
            Some(limit @ 1..=TASK_BOARD_TRIAGE_HISTORY_MAX_LIMIT) => limit,
            Some(_) => return None,
            None => TASK_BOARD_TRIAGE_HISTORY_DEFAULT_LIMIT,
        };
        Some((self.before_generation, limit))
    }
}

/// Response for `GET /v1/task-board/items/{item_id}/triage/history`. Descending
/// by `generation`; `next_before_generation` is the keyset cursor for the next
/// page, `None` once the oldest decision has been returned.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardTriageHistoryResponse {
    pub decisions: Vec<TaskBoardTriageDecisionRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_before_generation: Option<u64>,
}

#[cfg(test)]
mod tests {
    use super::{TASK_BOARD_TRIAGE_HISTORY_DEFAULT_LIMIT, TaskBoardTriageHistoryRequest};

    fn request(
        before_generation: Option<u64>,
        limit: Option<u32>,
    ) -> TaskBoardTriageHistoryRequest {
        TaskBoardTriageHistoryRequest {
            id: "item-1".to_string(),
            before_generation,
            limit,
        }
    }

    #[test]
    fn history_page_defaults_and_rejects_out_of_range_values() {
        assert_eq!(
            request(None, None).validated_page(),
            Some((None, TASK_BOARD_TRIAGE_HISTORY_DEFAULT_LIMIT))
        );
        assert_eq!(
            request(Some(1), Some(100)).validated_page(),
            Some((Some(1), 100))
        );
        assert!(request(Some(0), Some(1)).validated_page().is_none());
        assert!(
            request(Some(i64::MAX.unsigned_abs() + 1), Some(1))
                .validated_page()
                .is_none()
        );
        assert!(request(None, Some(0)).validated_page().is_none());
        assert!(request(None, Some(101)).validated_page().is_none());
    }

    #[test]
    fn history_cursor_accepts_a_lossless_decimal_string() {
        let request: TaskBoardTriageHistoryRequest = serde_json::from_value(serde_json::json!({
            "id": "item-1",
            "before_generation": i64::MAX.to_string(),
            "limit": 1,
        }))
        .expect("deserialize decimal cursor");

        assert_eq!(
            request.validated_page(),
            Some((Some(i64::MAX.unsigned_abs()), 1))
        );
    }
}
