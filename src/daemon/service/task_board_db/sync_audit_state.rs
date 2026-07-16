use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::{Arc, Mutex, OnceLock, PoisonError, Weak};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;

use super::TaskBoardSyncAuditTrigger;
use super::metrics::{ScopeAuditEvidence, ScopeOutcomeKind, SyncExecutionMetrics};

const BACKGROUND_FAILURE_REPEAT_INTERVAL: Duration = Duration::from_mins(15);

static BACKGROUND_AUDIT_STATE: OnceLock<Mutex<BackgroundAuditState>> = OnceLock::new();
static AUDIT_LANES: OnceLock<Mutex<HashMap<AuditLaneKey, Weak<AsyncMutex<()>>>>> = OnceLock::new();

type AuditLaneKey = (u64, TaskBoardSyncAuditTrigger);

#[derive(Debug, Clone)]
pub(super) struct AuditObservation {
    general_failure: Option<u64>,
    scope_issues: Vec<ScopeIssue>,
    successful_scopes: Vec<ScopeKey>,
    has_applied_change: bool,
}

impl AuditObservation {
    pub(super) fn for_request(error: Option<&CliError>, metrics: &SyncExecutionMetrics) -> Self {
        let scope_issues = metrics
            .scope_outcomes()
            .iter()
            .filter(|outcome| outcome.outcome.is_issue())
            .map(ScopeIssue::from)
            .collect::<Vec<_>>();
        let general_failure = scope_issues
            .is_empty()
            .then(|| error.map(error_fingerprint))
            .flatten();
        let successful_scopes = metrics
            .scope_outcomes()
            .iter()
            .filter(|outcome| outcome.outcome == ScopeOutcomeKind::Succeeded)
            .map(ScopeKey::from)
            .collect();
        Self {
            general_failure,
            scope_issues,
            successful_scopes,
            has_applied_change: metrics.has_applied_change(),
        }
    }

    pub(super) fn general(error: Option<&CliError>, has_applied_change: bool) -> Self {
        Self {
            general_failure: error.map(error_fingerprint),
            scope_issues: Vec::new(),
            successful_scopes: Vec::new(),
            has_applied_change,
        }
    }
}

#[derive(Debug)]
pub(super) struct PendingAudit {
    recovery: RecoveryDetail,
    commit: Option<StateCommit>,
}

impl PendingAudit {
    pub(super) fn untracked() -> Self {
        Self {
            recovery: RecoveryDetail::default(),
            commit: None,
        }
    }

    pub(super) fn add_recovery_to_payload(&self, payload: &mut Value) {
        self.recovery.add_to_payload(payload);
    }

    pub(super) fn commit(self) {
        let Some(commit) = self.commit else {
            return;
        };
        let state = background_state();
        state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .commit(commit);
    }
}

pub(super) fn plan_audit(
    db: &AsyncDaemonDb,
    trigger: TaskBoardSyncAuditTrigger,
    observation: AuditObservation,
) -> Option<PendingAudit> {
    plan_audit_at(
        database_fingerprint(db),
        trigger,
        observation,
        Instant::now(),
    )
}

pub(super) async fn acquire_audit_lane(
    db: &AsyncDaemonDb,
    trigger: TaskBoardSyncAuditTrigger,
) -> OwnedMutexGuard<()> {
    let key = (database_fingerprint(db), trigger);
    let lane = {
        let mut lanes = audit_lanes().lock().unwrap_or_else(PoisonError::into_inner);
        lanes.retain(|_, lane| lane.strong_count() > 0);
        lanes.get(&key).and_then(Weak::upgrade).unwrap_or_else(|| {
            let lane = Arc::new(AsyncMutex::new(()));
            lanes.insert(key, Arc::downgrade(&lane));
            lane
        })
    };
    lane.lock_owned().await
}

fn plan_audit_at(
    database_fingerprint: u64,
    trigger: TaskBoardSyncAuditTrigger,
    observation: AuditObservation,
    now: Instant,
) -> Option<PendingAudit> {
    if trigger == TaskBoardSyncAuditTrigger::Requested {
        return Some(PendingAudit::untracked());
    }
    let state = background_state();
    state.lock().unwrap_or_else(PoisonError::into_inner).plan(
        database_fingerprint,
        trigger,
        observation,
        now,
    )
}

fn background_state() -> &'static Mutex<BackgroundAuditState> {
    BACKGROUND_AUDIT_STATE.get_or_init(|| Mutex::new(BackgroundAuditState::default()))
}

fn audit_lanes() -> &'static Mutex<HashMap<AuditLaneKey, Weak<AsyncMutex<()>>>> {
    AUDIT_LANES.get_or_init(|| Mutex::new(HashMap::new()))
}

#[derive(Debug, Default)]
struct BackgroundAuditState {
    triggers: HashMap<(u64, TaskBoardSyncAuditTrigger), TriggerAuditState>,
}

impl BackgroundAuditState {
    fn plan(
        &self,
        database_fingerprint: u64,
        trigger: TaskBoardSyncAuditTrigger,
        observation: AuditObservation,
        now: Instant,
    ) -> Option<PendingAudit> {
        let scope = (database_fingerprint, trigger);
        let current = self.triggers.get(&scope);
        let recovery = RecoveryDetail::from_observation(current, &observation);
        let should_record = observation.has_applied_change
            || recovery.is_recovery()
            || general_issue_is_due(current, &observation, now)
            || scope_issue_is_due(current, &observation, now);
        should_record.then_some(PendingAudit {
            recovery,
            commit: Some(StateCommit {
                scope,
                observation,
                recorded_at: now,
            }),
        })
    }

    fn commit(&mut self, commit: StateCommit) {
        let state = self.triggers.entry(commit.scope).or_default();
        state.general_failure = commit
            .observation
            .general_failure
            .map(|fingerprint| IssueStamp {
                fingerprint,
                last_recorded_at: commit.recorded_at,
            });
        for issue in commit.observation.scope_issues {
            state.scope_issues.insert(
                issue.key,
                IssueStamp {
                    fingerprint: issue.fingerprint,
                    last_recorded_at: commit.recorded_at,
                },
            );
        }
        for scope in commit.observation.successful_scopes {
            state.scope_issues.remove(&scope);
        }
        if state.general_failure.is_none() && state.scope_issues.is_empty() {
            self.triggers.remove(&commit.scope);
        }
    }
}

#[derive(Debug, Default)]
struct TriggerAuditState {
    general_failure: Option<IssueStamp>,
    scope_issues: HashMap<ScopeKey, IssueStamp>,
}

#[derive(Debug, Clone, Copy)]
struct IssueStamp {
    fingerprint: u64,
    last_recorded_at: Instant,
}

#[derive(Debug)]
struct StateCommit {
    scope: (u64, TaskBoardSyncAuditTrigger),
    observation: AuditObservation,
    recorded_at: Instant,
}

#[derive(Debug, Clone)]
struct ScopeIssue {
    key: ScopeKey,
    fingerprint: u64,
}

impl From<&ScopeAuditEvidence> for ScopeIssue {
    fn from(evidence: &ScopeAuditEvidence) -> Self {
        Self {
            key: ScopeKey::from(evidence),
            fingerprint: evidence.issue_fingerprint(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct ScopeKey {
    provider: String,
    scope_id: String,
}

impl From<&ScopeAuditEvidence> for ScopeKey {
    fn from(evidence: &ScopeAuditEvidence) -> Self {
        Self {
            provider: evidence.provider.to_string(),
            scope_id: evidence.scope_id.clone(),
        }
    }
}

impl ScopeKey {
    fn payload(&self) -> Value {
        json!({
            "provider": self.provider,
            "scope_id": self.scope_id,
        })
    }
}

#[derive(Debug, Default)]
struct RecoveryDetail {
    general_failure: bool,
    scopes: Vec<ScopeKey>,
}

impl RecoveryDetail {
    fn from_observation(
        current: Option<&TriggerAuditState>,
        observation: &AuditObservation,
    ) -> Self {
        let general_failure = observation.general_failure.is_none()
            && current.is_some_and(|state| state.general_failure.is_some());
        let scopes = current.map_or_else(Vec::new, |state| {
            observation
                .successful_scopes
                .iter()
                .filter(|scope| state.scope_issues.contains_key(*scope))
                .cloned()
                .collect()
        });
        Self {
            general_failure,
            scopes,
        }
    }

    const fn is_recovery(&self) -> bool {
        self.general_failure || !self.scopes.is_empty()
    }

    fn add_to_payload(&self, payload: &mut Value) {
        if !self.is_recovery() {
            return;
        }
        payload["recovered"] = json!(true);
        payload["recovery"] = json!({
            "general_failure": self.general_failure,
            "scopes": self.scopes.iter().map(ScopeKey::payload).collect::<Vec<_>>(),
        });
    }
}

fn general_issue_is_due(
    current: Option<&TriggerAuditState>,
    observation: &AuditObservation,
    now: Instant,
) -> bool {
    observation.general_failure.is_some_and(|fingerprint| {
        issue_is_due(
            current.and_then(|state| state.general_failure.as_ref()),
            fingerprint,
            now,
        )
    })
}

fn scope_issue_is_due(
    current: Option<&TriggerAuditState>,
    observation: &AuditObservation,
    now: Instant,
) -> bool {
    observation.scope_issues.iter().any(|issue| {
        issue_is_due(
            current.and_then(|state| state.scope_issues.get(&issue.key)),
            issue.fingerprint,
            now,
        )
    })
}

fn issue_is_due(current: Option<&IssueStamp>, fingerprint: u64, now: Instant) -> bool {
    current.is_none_or(|current| {
        current.fingerprint != fingerprint
            || now.saturating_duration_since(current.last_recorded_at)
                >= BACKGROUND_FAILURE_REPEAT_INTERVAL
    })
}

fn database_fingerprint(db: &AsyncDaemonDb) -> u64 {
    fingerprint(db.storage_path())
}

fn error_fingerprint(error: &CliError) -> u64 {
    let mut hasher = DefaultHasher::new();
    error.code().hash(&mut hasher);
    error.message().hash(&mut hasher);
    hasher.finish()
}

fn fingerprint<T: Hash + ?Sized>(value: &T) -> u64 {
    let mut hasher = DefaultHasher::new();
    value.hash(&mut hasher);
    hasher.finish()
}
