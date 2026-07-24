use serde::{Deserialize, Serialize};

/// Stable identity for the agent-judgment evaluator, as distinct from
/// [`super::triage::BUILTIN_V1_EVALUATOR_IDENTITY`] and
/// [`super::triage_rules::RUNTIME_RULES_EVALUATOR_IDENTITY`]. A verdict
/// stamped with this identity always came from an agent escalation, never a
/// deterministic check -- the same trust marker every other evaluator
/// identity already provides, with no separate "is this agent-produced"
/// field needed anywhere it is displayed.
pub const AGENT_V1_EVALUATOR_IDENTITY: &str = "task_board.triage.agent_v1";
pub const AGENT_V1_EVALUATOR_VERSION: u32 = 1;

/// The only two escalation states ever exposed to a reader. A terminal
/// state's effect is either a landed decision or nothing at all, so there is
/// nothing useful to show once an escalation resolves -- a caller that wants
/// history reads the generic `audit_events` trail instead.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub enum TaskBoardTriageEscalationStatus {
    Pending,
    Running,
}

/// Bounded, off-by-default configuration for the escalation feature.
/// Resolved once at daemon startup from `HARNESS_FEATURE_TASK_BOARD_TRIAGE_ESCALATION`
/// and the `HARNESS_TASK_BOARD_TRIAGE_ESCALATION_*` env vars (see
/// `src/feature_flags.rs`), then threaded by value into both the enqueue
/// choke point (`enabled`, `max_pending`) and the background executor
/// (`max_concurrent`, `timeout_seconds`). Deliberately not a persisted
/// settings table -- this is a deploy-time tuning surface, not a product
/// surface.
#[derive(Debug, Clone, Copy)]
pub struct TaskBoardTriageEscalationConfig {
    pub enabled: bool,
    pub max_concurrent: usize,
    pub max_pending: usize,
    pub timeout_seconds: u64,
}

/// Outcome of one verdict-report call. Never partially applied: `Accepted`
/// means the decision landed through the ordinary choke point exactly like
/// any other evaluator's verdict; every `Rejected` variant means nothing was
/// written to `task_board_triage_decisions` at all, only the escalation
/// row's own status. This type is daemon-local (the endpoint itself is
/// HTTP-only, not exposed to remote or Swift clients -- see the route
/// catalog's `Exempt` classification), so it carries no `Serialize` derive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskBoardTriageEscalationVerdictOutcome {
    Accepted,
    Rejected(TaskBoardTriageEscalationRejectReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskBoardTriageEscalationRejectReason {
    /// No `running` escalation with this id and token exists -- either the
    /// id is unknown, already terminal, or the token does not match.
    UnknownRunningEscalation,
    /// The item no longer qualifies (deleted, dispatched, wrong lane) for a
    /// triage decision at all.
    ItemIneligible,
    /// A human set an override on this item after escalation started.
    OverrideActive,
    /// A dispatch reservation claimed this item after escalation started.
    ReservationHeld,
    /// The item's evidence changed after escalation started; the row was
    /// marked stale and a fresh escalation was enqueued for the current
    /// evidence if the item is still `Undecided`.
    StaleEvidence,
}

impl TaskBoardTriageEscalationConfig {
    pub const DEFAULT_MAX_CONCURRENT: usize = 2;
    pub const DEFAULT_MAX_PENDING: usize = 20;
    pub const DEFAULT_TIMEOUT_SECONDS: u64 = 180;

    /// The feature is off by default, mirroring `HARNESS_FEATURE_REVIEWS_BACKGROUND_AUTO`:
    /// it spawns real agent processes without same-moment human confirmation.
    #[must_use]
    pub const fn disabled() -> Self {
        Self {
            enabled: false,
            max_concurrent: Self::DEFAULT_MAX_CONCURRENT,
            max_pending: Self::DEFAULT_MAX_PENDING,
            timeout_seconds: Self::DEFAULT_TIMEOUT_SECONDS,
        }
    }
}
