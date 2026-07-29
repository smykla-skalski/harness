use std::collections::BTreeMap;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use harness_kernel::errors::{CliError, CliErrorKind};
use harness_workspace::workspace::utc_now;

use crate::normalize_repository_slug;

mod gates;
mod github_source;

pub use gates::{
    CheckGate, CheckState, Mergeability, PullRequestMergeGates, ReviewDecision, ReviewGate,
};
pub use github_source::GitHubPullRequestEvidenceSource;

/// Canonical identity of a pull request: an `owner/repo` slug and number in one
/// normalized shape. It is the shared vocabulary discovery and execution are
/// meant to name a pull request by, instead of each deriving its own shape from a
/// separate query.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct PullRequestIdentity {
    /// `owner/repo` slug the pull request lives in.
    pub repository: String,
    pub number: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

impl PullRequestIdentity {
    /// Build an identity from an owner, repository name, and number. The slug is
    /// canonicalized (trimmed and lowercased), since GitHub treats `owner/repo`
    /// case-insensitively and later logic compares external ids by string.
    #[must_use]
    pub fn new(owner: &str, repo: &str, number: u64) -> Self {
        Self {
            repository: canonical_repository(&format!("{owner}/{repo}")),
            number,
            url: None,
        }
    }

    /// Build an identity from an `owner/repo` slug, canonicalizing it the same
    /// way as [`Self::new`].
    #[must_use]
    pub fn from_slug(repository: impl Into<String>, number: u64) -> Self {
        Self {
            repository: canonical_repository(&repository.into()),
            number,
            url: None,
        }
    }

    /// Attach the canonical html URL.
    #[must_use]
    pub fn with_url(mut self, url: Option<String>) -> Self {
        self.url = url;
        self
    }

    /// The provider-scoped external id (`owner/repo#number`) discovery and
    /// execution both key a pull request by.
    #[must_use]
    pub fn external_id(&self) -> String {
        format!("{}#{}", self.repository, self.number)
    }

    /// The `owner` half of the repository slug, or the whole slug when it holds
    /// no `/`.
    #[must_use]
    pub fn owner(&self) -> &str {
        self.repository
            .split_once('/')
            .map_or(self.repository.as_str(), |(owner, _)| owner)
    }

    /// The repository-name half of the slug, or the whole slug when it holds no
    /// `/`.
    #[must_use]
    pub fn repo(&self) -> &str {
        self.repository
            .split_once('/')
            .map_or(self.repository.as_str(), |(_, repo)| repo)
    }

    fn key(&self) -> (String, u64) {
        (self.repository.clone(), self.number)
    }
}

/// Lifecycle state of an observed pull request, independent of the merge gates a
/// later slice layers on top.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PullRequestLifecycle {
    Open,
    Closed,
    Merged,
}

/// One fresh read of a pull request's normalized identity and current state.
///
/// This is the shared evidence vocabulary the review workflows read from. Later
/// slices extend it with merge gates, check results, and review decisions; the
/// identity and lifecycle facts here stay the common ground discovery and
/// execution agree on for a given observed revision.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PullRequestEvidence {
    pub identity: PullRequestIdentity,
    /// The head commit SHA every downstream decision must bind to.
    pub head_revision: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    pub lifecycle: PullRequestLifecycle,
    pub is_draft: bool,
    /// Every merge gate read off this same snapshot.
    pub gates: PullRequestMergeGates,
    /// ISO-8601 instant the evidence was read, so staleness is always visible.
    pub observed_at: String,
}

impl PullRequestEvidence {
    #[must_use]
    pub fn is_open(&self) -> bool {
        matches!(self.lifecycle, PullRequestLifecycle::Open)
    }
}

/// The result of asking a source for a pull request.
///
/// `Missing` means the provider answered and the pull request is absent. A
/// provider or transport failure stays in the `Err` arm of the read, so a flaky
/// read is never mistaken for a deleted pull request - the distinction the whole
/// umbrella depends on when it decides whether an action is still safe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PullRequestEvidenceRead {
    Found(Box<PullRequestEvidence>),
    /// The pull request was absent when observed. The timestamp keeps a missing
    /// read's staleness as visible as a found one's.
    Missing {
        identity: PullRequestIdentity,
        observed_at: String,
    },
}

impl PullRequestEvidenceRead {
    #[must_use]
    pub fn found(evidence: PullRequestEvidence) -> Self {
        Self::Found(Box::new(evidence))
    }

    #[must_use]
    pub fn missing(identity: PullRequestIdentity, observed_at: String) -> Self {
        Self::Missing {
            identity,
            observed_at,
        }
    }

    #[must_use]
    pub fn evidence(&self) -> Option<&PullRequestEvidence> {
        match self {
            Self::Found(evidence) => Some(evidence),
            Self::Missing { .. } => None,
        }
    }

    #[must_use]
    pub fn is_missing(&self) -> bool {
        matches!(self, Self::Missing { .. })
    }

    /// When this read was observed, whether the pull request was found or
    /// missing.
    #[must_use]
    pub fn observed_at(&self) -> &str {
        match self {
            Self::Found(evidence) => &evidence.observed_at,
            Self::Missing { observed_at, .. } => observed_at,
        }
    }
}

/// A source of fresh pull request evidence.
///
/// One read returns the normalized identity and current state. The real source
/// talks to GitHub; the in-memory source drives tests without a live account.
#[async_trait]
pub trait PullRequestEvidenceSource: Send + Sync {
    /// Read the current evidence for one pull request.
    ///
    /// # Errors
    /// Returns a provider or transport error. A pull request the provider
    /// reports as absent is `Ok(PullRequestEvidenceRead::Missing)`, never an
    /// error.
    async fn read_pull_request_evidence(
        &self,
        identity: &PullRequestIdentity,
    ) -> Result<PullRequestEvidenceRead, CliError>;
}

enum StoredRead {
    Found(Box<PullRequestEvidence>),
    Missing,
    Failure(String),
}

/// An in-memory [`PullRequestEvidenceSource`] for tests. Unseeded pull requests
/// read back as `Missing`, so a test only states the reads it cares about.
#[derive(Default)]
pub struct InMemoryPullRequestEvidenceSource {
    reads: BTreeMap<(String, u64), StoredRead>,
}

impl InMemoryPullRequestEvidenceSource {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Seed a found pull request.
    #[must_use]
    pub fn with_evidence(mut self, evidence: PullRequestEvidence) -> Self {
        self.reads.insert(
            evidence.identity.key(),
            StoredRead::Found(Box::new(evidence)),
        );
        self
    }

    /// Seed an explicitly-absent pull request. Redundant with the default, but
    /// makes a test's intent explicit next to a found one.
    #[must_use]
    pub fn with_missing(mut self, identity: &PullRequestIdentity) -> Self {
        self.reads.insert(identity.key(), StoredRead::Missing);
        self
    }

    /// Seed a provider failure for a pull request.
    #[must_use]
    pub fn with_failure(
        mut self,
        identity: &PullRequestIdentity,
        message: impl Into<String>,
    ) -> Self {
        self.reads
            .insert(identity.key(), StoredRead::Failure(message.into()));
        self
    }
}

#[async_trait]
impl PullRequestEvidenceSource for InMemoryPullRequestEvidenceSource {
    async fn read_pull_request_evidence(
        &self,
        identity: &PullRequestIdentity,
    ) -> Result<PullRequestEvidenceRead, CliError> {
        match self.reads.get(&identity.key()) {
            Some(StoredRead::Found(evidence)) => {
                Ok(PullRequestEvidenceRead::Found(evidence.clone()))
            }
            Some(StoredRead::Failure(message)) => {
                Err(CliErrorKind::workflow_io(message.clone()).into())
            }
            Some(StoredRead::Missing) | None => Ok(PullRequestEvidenceRead::missing(
                identity.clone(),
                utc_now(),
            )),
        }
    }
}

// A valid `owner/repo` is canonicalized (trimmed and lowercased). Anything else
// cannot be canonicalized, so it is kept verbatim (only trimmed) rather than
// lowercased into a plausible-looking slug, so a malformed identity stays
// recognizably wrong instead of masquerading as a real repository. Slugs are
// validated upstream via `parse_github_repository`; this is the last-line
// normalization, not the validation boundary.
fn canonical_repository(raw: &str) -> String {
    normalize_repository_slug(Some(raw)).unwrap_or_else(|| raw.trim().to_string())
}

#[cfg(test)]
mod tests;
