use std::collections::{BTreeMap, VecDeque};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Serialize;

use harness_workspace::workspace::utc_now;

use super::budget::{GitHubRateBudget, GitHubRateResource};
use super::cache::GitHubCacheState;
use super::types::{GitHubApiStatus, GitHubOperationSpend, GitHubPriority};

const EVENT_WINDOW: Duration = Duration::from_hours(1);
const MAX_MEMORY_EVENTS: usize = 4096;

#[derive(Debug, Clone)]
struct UsageEvent {
    observed_at: SystemTime,
    operation: String,
    network: bool,
    graphql_cost: u32,
    cache_state: Option<GitHubCacheState>,
    deferred_budget: bool,
}

#[derive(Debug, Serialize)]
struct UsageJournalRecord<'a> {
    observed_at: String,
    operation: &'a str,
    resource: GitHubRateResource,
    priority: GitHubPriority,
    network: bool,
    status: Option<u16>,
    graphql_cost: u32,
    cache_state: Option<&'a str>,
    deferred_budget: bool,
}

pub struct GitHubUsageRecorder {
    events: Mutex<VecDeque<UsageEvent>>,
    journal_path: PathBuf,
}

impl GitHubUsageRecorder {
    // Takes the daemon root as a parameter rather than resolving it
    // internally, for the same reason `GitHubCache::new` does (see that
    // constructor and the crate-level docs). An empty root - the
    // placeholder test builds construct this with, see `GitHubCache::new` -
    // stays an empty `journal_path` rather than joining a bare relative
    // filename, so `append_journal` has an unambiguous "disabled" signal to
    // check instead of a path that merely looks wrong.
    pub(crate) fn new(daemon_root: &Path) -> Self {
        let journal_path = if daemon_root.as_os_str().is_empty() {
            PathBuf::new()
        } else {
            daemon_root.join("github-usage.jsonl")
        };
        Self {
            events: Mutex::new(VecDeque::new()),
            journal_path,
        }
    }

    pub(crate) fn record_network(
        &self,
        operation: &str,
        resource: GitHubRateResource,
        priority: GitHubPriority,
        status: Option<u16>,
        graphql_cost: u32,
    ) {
        self.push_event(UsageEvent {
            observed_at: SystemTime::now(),
            operation: operation.to_string(),
            network: true,
            graphql_cost,
            cache_state: None,
            deferred_budget: false,
        });
        self.append_journal(&UsageJournalRecord {
            observed_at: utc_now(),
            operation,
            resource,
            priority,
            network: true,
            status,
            graphql_cost,
            cache_state: None,
            deferred_budget: false,
        });
    }

    pub(crate) fn record_cache_hit(&self, operation: &str, state: GitHubCacheState) {
        self.push_event(UsageEvent {
            observed_at: SystemTime::now(),
            operation: operation.to_string(),
            network: false,
            graphql_cost: 0,
            cache_state: Some(state),
            deferred_budget: false,
        });
    }

    pub(crate) fn record_deferred_budget(&self, operation: &str, state: GitHubCacheState) {
        self.push_event(UsageEvent {
            observed_at: SystemTime::now(),
            operation: operation.to_string(),
            network: false,
            graphql_cost: 0,
            cache_state: Some(state),
            deferred_budget: true,
        });
    }

    pub(crate) async fn status(
        &self,
        budget: &GitHubRateBudget,
        data_revision: u64,
    ) -> GitHubApiStatus {
        let events = self.window_events();
        GitHubApiStatus {
            data_revision,
            buckets: budget.bucket_statuses().await,
            cooling: budget.cooldown_statuses().await,
            last_hour_network_requests: count_network(&events),
            last_hour_graphql_points: sum_graphql(&events),
            cache_hits: count_cache(&events, |_| true),
            cache_stale_hits: count_cache(&events, |state| state == GitHubCacheState::Stale),
            cache_deferred_hits: events.iter().filter(|event| event.deferred_budget).count() as u64,
            deferred_budget: events.iter().filter(|event| event.deferred_budget).count() as u64,
            top_operations: top_operations(&events),
        }
    }

    fn push_event(&self, event: UsageEvent) {
        if let Ok(mut guard) = self.events.lock() {
            guard.push_back(event);
            prune_events(&mut guard);
        }
    }

    fn window_events(&self) -> Vec<UsageEvent> {
        let Ok(mut guard) = self.events.lock() else {
            return Vec::new();
        };
        prune_events(&mut guard);
        guard.iter().cloned().collect()
    }

    fn append_journal(&self, record: &UsageJournalRecord<'_>) {
        // Test builds (this crate's own, or a downstream crate's via
        // `test-support`) construct the recorder with an empty placeholder
        // root - see `GitHubCache::new` - so `journal_path` here is a bare
        // relative filename with no real directory behind it. Bail out
        // rather than let it land relative to the test process's current
        // directory.
        if self.journal_path.as_os_str().is_empty() {
            return;
        }
        let Some(parent) = self.journal_path.parent() else {
            return;
        };
        if fs_err::create_dir_all(parent).is_err() {
            return;
        }
        let Ok(mut file) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.journal_path)
        else {
            return;
        };
        if let Ok(raw) = serde_json::to_string(record) {
            let _ = writeln!(file, "{raw}");
        }
    }
}

fn prune_events(events: &mut VecDeque<UsageEvent>) {
    let cutoff = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .saturating_sub(EVENT_WINDOW);
    while events.len() > MAX_MEMORY_EVENTS {
        events.pop_front();
    }
    while let Some(front) = events.front() {
        let age = front
            .observed_at
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        if age >= cutoff {
            break;
        }
        events.pop_front();
    }
}

fn count_network(events: &[UsageEvent]) -> u64 {
    events.iter().filter(|event| event.network).count() as u64
}

fn sum_graphql(events: &[UsageEvent]) -> u64 {
    events
        .iter()
        .map(|event| u64::from(event.graphql_cost))
        .sum()
}

fn count_cache(events: &[UsageEvent], predicate: impl Fn(GitHubCacheState) -> bool) -> u64 {
    events
        .iter()
        .filter_map(|event| event.cache_state)
        .filter(|state| predicate(*state))
        .count() as u64
}

fn top_operations(events: &[UsageEvent]) -> Vec<GitHubOperationSpend> {
    let mut counts: BTreeMap<String, (u64, u64)> = BTreeMap::new();
    for event in events {
        let entry = counts.entry(event.operation.clone()).or_default();
        if event.network {
            entry.0 += 1;
        }
        entry.1 += u64::from(event.graphql_cost);
    }
    let mut rows = counts
        .into_iter()
        .map(
            |(operation, (network_requests, graphql_points))| GitHubOperationSpend {
                operation,
                network_requests,
                graphql_points,
            },
        )
        .collect::<Vec<_>>();
    rows.sort_by(|left, right| {
        right
            .graphql_points
            .cmp(&left.graphql_points)
            .then_with(|| right.network_requests.cmp(&left.network_requests))
            .then_with(|| left.operation.cmp(&right.operation))
    });
    rows.truncate(5);
    rows
}
