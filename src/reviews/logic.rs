//! Behaviour for the reviews wire types.
//!
//! Holds the serde default helpers, normalization helper, and impl blocks
//! that derive request/response state from the structs declared in
//! [`crate::reviews::types`].

use std::collections::{BTreeMap, BTreeSet};

use super::enums::{
    ReviewCheckStatus, ReviewMergeableState, ReviewPullRequestState, ReviewReviewStatus,
};
use super::types::{
    ReviewItem, ReviewRepositoryLabel, ReviewTarget, ReviewTargetFlags, ReviewsActionCapabilities,
    ReviewsBodyRequest, ReviewsCapabilitiesResponse, ReviewsPolicyHistoryRequest,
    ReviewsPolicyPreviewRequest, ReviewsPolicyRunStartRequest, ReviewsPolicyStatusRequest,
    ReviewsPolicySubject, ReviewsPullRequestReference, ReviewsPullRequestResolveRequest,
    ReviewsQueryRequest, ReviewsQueryResponse, ReviewsRefreshRequest,
    ReviewsRepositoryCatalogRequest, ReviewsSummary,
};

const DEFAULT_BACKPORT_PATTERNS: &[&str] = &[
    r"(?i)\s*\(backport\s+of\s+#(?P<number>\d+)\)\s*$",
    r"(?i)\s*\[backport\s+of\s+#(?P<number>\d+)\]\s*$",
];

pub(super) fn default_backport_detection_enabled() -> bool {
    true
}

pub(super) fn default_backport_patterns() -> Vec<String> {
    DEFAULT_BACKPORT_PATTERNS
        .iter()
        .map(ToString::to_string)
        .collect()
}

pub(super) fn default_viewer_can_update() -> bool {
    true
}

pub(super) fn default_viewer_can_merge_as_admin() -> bool {
    false
}

pub(super) fn default_cache_max_age_seconds() -> u64 {
    600
}

pub(super) fn default_pull_request_state() -> ReviewPullRequestState {
    ReviewPullRequestState::Open
}

pub(super) fn default_reviews_policy_workflow_id() -> String {
    "reviews_auto".to_owned()
}

impl Default for ReviewsQueryRequest {
    fn default() -> Self {
        Self {
            authors: Vec::new(),
            organizations: Vec::new(),
            repositories: Vec::new(),
            exclude_repositories: Vec::new(),
            force_refresh: false,
            cache_max_age_seconds: default_cache_max_age_seconds(),
            backport_detection_enabled: default_backport_detection_enabled(),
            backport_patterns: default_backport_patterns(),
        }
    }
}

impl ReviewsQueryRequest {
    #[must_use]
    pub fn normalized_authors(&self) -> Vec<String> {
        normalized_entries(&self.authors)
    }

    #[must_use]
    pub fn normalized_organizations(&self) -> Vec<String> {
        normalized_entries(&self.organizations)
    }

    #[must_use]
    pub fn normalized_repositories(&self) -> Vec<String> {
        normalized_entries(&self.repositories)
    }

    #[must_use]
    pub fn normalized_exclude_repositories(&self) -> Vec<String> {
        normalized_entries(&self.exclude_repositories)
    }

    #[must_use]
    pub fn normalized_backport_patterns(&self) -> Vec<String> {
        normalized_preserving_order(&self.backport_patterns)
    }

    #[must_use]
    pub fn cache_key(&self) -> String {
        let backport_enabled = self.backport_detection_enabled;
        let backport_patterns = self.normalized_backport_patterns().join("\u{1f}");
        format!(
            "authors={}|orgs={}|repos={}|exclude={}|backports={backport_enabled}|backport_patterns={backport_patterns}",
            self.normalized_authors().join(","),
            self.normalized_organizations().join(","),
            self.normalized_repositories().join(","),
            self.normalized_exclude_repositories().join(","),
        )
    }

    #[must_use]
    pub fn cache_max_age_seconds(&self) -> u64 {
        self.cache_max_age_seconds.max(1)
    }

    #[must_use]
    pub fn organization_only_request(&self) -> Self {
        Self {
            authors: self.normalized_authors(),
            organizations: self.normalized_organizations(),
            repositories: Vec::new(),
            exclude_repositories: self.normalized_exclude_repositories(),
            force_refresh: self.force_refresh,
            cache_max_age_seconds: self.cache_max_age_seconds(),
            backport_detection_enabled: self.backport_detection_enabled,
            backport_patterns: self.normalized_backport_patterns(),
        }
    }

    #[must_use]
    pub fn repository_only_request(&self, repository: &str) -> Self {
        Self {
            authors: self.normalized_authors(),
            organizations: Vec::new(),
            repositories: vec![repository.to_string()],
            exclude_repositories: self.normalized_exclude_repositories(),
            force_refresh: self.force_refresh,
            cache_max_age_seconds: self.cache_max_age_seconds(),
            backport_detection_enabled: self.backport_detection_enabled,
            backport_patterns: self.normalized_backport_patterns(),
        }
    }
}

impl Default for ReviewsRefreshRequest {
    fn default() -> Self {
        Self {
            targets: Vec::new(),
            backport_detection_enabled: default_backport_detection_enabled(),
            backport_patterns: default_backport_patterns(),
        }
    }
}

impl ReviewsRefreshRequest {
    #[must_use]
    pub fn normalized_backport_patterns(&self) -> Vec<String> {
        normalized_preserving_order(&self.backport_patterns)
    }
}

impl ReviewsRepositoryCatalogRequest {
    #[must_use]
    pub fn normalized_organization(&self) -> String {
        self.organization.trim().to_lowercase()
    }
}

impl Default for ReviewsPullRequestResolveRequest {
    fn default() -> Self {
        Self {
            references: Vec::new(),
            backport_detection_enabled: default_backport_detection_enabled(),
            backport_patterns: default_backport_patterns(),
        }
    }
}

impl ReviewsPullRequestReference {
    #[must_use]
    pub fn normalized_repository(&self) -> String {
        self.repository.trim().to_lowercase()
    }

    #[must_use]
    pub fn key(&self) -> String {
        format!("{}#{}", self.normalized_repository(), self.number)
    }
}

impl ReviewsPullRequestResolveRequest {
    #[must_use]
    pub fn normalized_references(&self) -> Vec<ReviewsPullRequestReference> {
        let mut seen = BTreeSet::new();
        self.references
            .iter()
            .filter_map(|reference| {
                let repository = reference.normalized_repository();
                let (owner, name) = repository.split_once('/')?;
                if owner.is_empty()
                    || name.is_empty()
                    || name.contains('/')
                    || reference.number == 0
                {
                    return None;
                }
                let key = format!("{repository}#{}", reference.number);
                if !seen.insert(key) {
                    return None;
                }
                Some(ReviewsPullRequestReference {
                    repository,
                    number: reference.number,
                })
            })
            .collect()
    }

    #[must_use]
    pub fn normalized_backport_patterns(&self) -> Vec<String> {
        normalized_preserving_order(&self.backport_patterns)
    }
}

impl ReviewsPolicySubject {
    #[must_use]
    pub fn from_target(target: &ReviewTarget) -> Self {
        Self {
            repository: target.repository.clone(),
            pull_request_number: target.number,
        }
    }

    #[must_use]
    pub fn from_subject_key(subject_key: &str) -> Option<Self> {
        let (repository, pull_request_number) = subject_key.rsplit_once('#')?;
        let pull_request_number = pull_request_number.parse().ok()?;
        Some(Self {
            repository: repository.to_owned(),
            pull_request_number,
        })
    }

    #[must_use]
    pub fn subject_key(&self) -> String {
        format!("{}#{}", self.repository, self.pull_request_number)
    }
}

impl ReviewsPolicyPreviewRequest {
    #[must_use]
    pub fn normalized_workflow_id(&self) -> String {
        normalized_workflow_id(&self.workflow_id)
    }

    #[must_use]
    pub fn subject(&self) -> ReviewsPolicySubject {
        ReviewsPolicySubject::from_target(&self.target)
    }
}

impl ReviewsPolicyRunStartRequest {
    #[must_use]
    pub fn normalized_workflow_id(&self) -> String {
        normalized_workflow_id(&self.workflow_id)
    }

    #[must_use]
    pub fn subject(&self) -> ReviewsPolicySubject {
        ReviewsPolicySubject::from_target(&self.target)
    }
}

impl ReviewsPolicyStatusRequest {
    #[must_use]
    pub fn normalized_workflow_id(&self) -> String {
        normalized_workflow_id(&self.workflow_id)
    }
}

impl ReviewsPolicyHistoryRequest {
    #[must_use]
    pub fn normalized_workflow_id(&self) -> String {
        normalized_workflow_id(&self.workflow_id)
    }
}

impl ReviewsBodyRequest {
    #[must_use]
    pub fn normalized_pull_request_id(&self) -> String {
        self.pull_request_id.trim().to_string()
    }

    #[must_use]
    pub fn cache_max_age_seconds(&self) -> u64 {
        self.cache_max_age_seconds.max(1)
    }
}

impl ReviewsQueryResponse {
    #[must_use]
    pub fn new(items: Vec<ReviewItem>, fetched_at: String) -> Self {
        Self {
            fetched_at,
            from_cache: false,
            summary: ReviewsSummary::from_items(&items),
            items,
            repository_labels: BTreeMap::new(),
            viewer_login: None,
        }
    }

    pub fn set_repository_labels(
        &mut self,
        repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>>,
    ) {
        self.repository_labels = repository_labels;
    }

    pub fn set_viewer_login(&mut self, viewer_login: Option<String>) {
        self.viewer_login = viewer_login;
    }
}

impl ReviewsCapabilitiesResponse {
    #[must_use]
    pub fn current() -> Self {
        Self {
            schema_version: 1,
            features: ReviewsActionCapabilities {
                supports_action_preview: true,
                supports_check_run_links: true,
                supports_repository_sync_health: true,
            },
            supports_persistent_action_diagnostics: true,
        }
    }
}

impl ReviewsSummary {
    #[must_use]
    pub fn from_items(items: &[ReviewItem]) -> Self {
        Self {
            total: items.len(),
            review_required: items
                .iter()
                .filter(|item| item.review_status == ReviewReviewStatus::ReviewRequired)
                .count(),
            ready_to_merge: items.iter().filter(|item| item.is_ready_to_merge()).count(),
            auto_approvable: items
                .iter()
                .filter(|item| item.is_auto_approvable())
                .count(),
            waiting_on_checks: items
                .iter()
                .filter(|item| item.check_status == ReviewCheckStatus::Pending)
                .count(),
            blocked: items
                .iter()
                .filter(|item| item.requires_attention())
                .count(),
        }
    }
}

impl ReviewItem {
    #[must_use]
    pub fn target(&self) -> ReviewTarget {
        ReviewTarget {
            pull_request_id: self.pull_request_id.clone(),
            repository_id: self.repository_id.clone(),
            repository: self.repository.clone(),
            number: self.number,
            url: self.url.clone(),
            state: self.state,
            head_sha: self.head_sha.clone(),
            mergeable: self.mergeable,
            review_status: self.review_status,
            check_status: self.check_status,
            flags: ReviewTargetFlags {
                is_draft: self.flags.is_draft,
                policy_blocked: self.flags.policy_blocked,
                viewer_can_update: self.flags.viewer_can_update,
            },
            viewer_can_merge_as_admin: self.viewer_can_merge_as_admin,
            required_failed_check_names: self.required_failed_check_names.clone(),
            check_suite_ids: self
                .checks
                .iter()
                .filter_map(|check| check.check_suite_id.clone())
                .collect(),
            has_conflict_markers: self.has_conflict_markers,
            viewer_has_active_approval: self.viewer_has_active_approval,
            auto_merge_enabled: self.auto_merge_enabled,
            approval_requirement_satisfied_after_viewer_approval: self
                .approval_requirement_satisfied_after_viewer_approval,
        }
    }

    #[must_use]
    pub fn is_auto_approvable(&self) -> bool {
        self.target().is_auto_approvable()
    }

    #[must_use]
    pub fn is_ready_to_merge(&self) -> bool {
        self.target().is_auto_mergeable()
    }

    #[must_use]
    pub fn requires_attention(&self) -> bool {
        self.flags.policy_blocked
            || self.mergeable == ReviewMergeableState::Conflicting
            || self.review_status == ReviewReviewStatus::ChangesRequested
            || self.check_status == ReviewCheckStatus::Failure
    }
}

impl ReviewTarget {
    #[must_use]
    pub fn subject_key(&self) -> String {
        format!("{}#{}", self.repository, self.number)
    }

    #[must_use]
    pub fn can_attempt_manual_approval(&self) -> bool {
        self.flags.viewer_can_update
            && self.state == ReviewPullRequestState::Open
            && matches!(
                self.review_status,
                ReviewReviewStatus::ReviewRequired | ReviewReviewStatus::None
            )
    }

    #[must_use]
    pub fn can_attempt_manual_merge(&self) -> bool {
        self.flags.viewer_can_update
            && self.state == ReviewPullRequestState::Open
            && !self.flags.is_draft
            && self.mergeable != ReviewMergeableState::Conflicting
    }

    #[must_use]
    pub fn can_attempt_rerun_checks(&self) -> bool {
        self.flags.viewer_can_update && !self.check_suite_ids.is_empty()
    }

    #[must_use]
    pub fn can_add_label(&self) -> bool {
        self.flags.viewer_can_update && self.state == ReviewPullRequestState::Open
    }

    #[must_use]
    pub fn is_auto_approvable(&self) -> bool {
        self.flags.viewer_can_update
            && self.state == ReviewPullRequestState::Open
            && self.check_status == ReviewCheckStatus::Success
            && matches!(
                self.review_status,
                ReviewReviewStatus::ReviewRequired | ReviewReviewStatus::None
            )
            && self.mergeable != ReviewMergeableState::Conflicting
            && self.has_conflict_markers != Some(true)
    }

    #[must_use]
    pub fn is_auto_mergeable(&self) -> bool {
        self.flags.viewer_can_update
            && self.state == ReviewPullRequestState::Open
            && !self.flags.is_draft
            && matches!(
                self.review_status,
                ReviewReviewStatus::Approved | ReviewReviewStatus::None
            )
            && self.check_status == ReviewCheckStatus::Success
            && self.mergeable != ReviewMergeableState::Conflicting
            && !self.flags.policy_blocked
            && self.has_conflict_markers != Some(true)
    }
}

fn normalized_entries(entries: &[String]) -> Vec<String> {
    let mut normalized = entries
        .iter()
        .map(|entry| entry.trim())
        .filter(|entry| !entry.is_empty())
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    normalized.sort();
    normalized.dedup();
    normalized
}

fn normalized_preserving_order(entries: &[String]) -> Vec<String> {
    let mut normalized = Vec::new();
    for entry in entries {
        let trimmed = entry.trim();
        if trimmed.is_empty() || normalized.iter().any(|existing| existing == trimmed) {
            continue;
        }
        normalized.push(trimmed.to_owned());
    }
    normalized
}

fn normalized_workflow_id(workflow_id: &str) -> String {
    let trimmed = workflow_id.trim();
    if trimmed.is_empty() {
        default_reviews_policy_workflow_id()
    } else {
        // Lower-case so preview, start, status, and run storage all key the
        // workflow identically regardless of how it was typed in the canvas.
        trimmed.to_ascii_lowercase()
    }
}
