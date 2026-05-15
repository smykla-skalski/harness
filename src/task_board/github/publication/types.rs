use serde::{Deserialize, Serialize};

use crate::task_board::TaskBoardGitRuntimeProfile;

pub(super) struct LocalBranchSnapshot {
    pub(super) head_tree_sha: String,
    pub(super) commit_message: String,
    pub(super) author: LocalCommitAuthor,
    pub(super) committer: LocalCommitAuthor,
    pub(super) profile: TaskBoardGitRuntimeProfile,
    pub(super) existing_signature: Option<LocalCommitSignature>,
    pub(super) root_tree: LocalTreeSnapshot,
}

pub(super) struct LocalCommitAuthor {
    pub(super) request: GitHubCommitAuthorRequest,
    pub(super) git_actor: String,
}

pub(super) struct LocalTreeSnapshot {
    pub(super) entries: Vec<LocalTreeEntry>,
}

pub(super) enum LocalTreeEntry {
    Blob {
        path: String,
        mode: String,
        content: Vec<u8>,
    },
    Tree {
        path: String,
        mode: String,
        tree: LocalTreeSnapshot,
    },
    Commit {
        path: String,
        mode: String,
        sha: String,
    },
}

pub(super) enum BranchPublicationMode {
    Create { parent_sha: String },
    Update { parent_sha: String },
}

impl BranchPublicationMode {
    pub(super) fn parent_sha(&self) -> &str {
        match self {
            Self::Create { parent_sha } | Self::Update { parent_sha } => parent_sha.as_str(),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum LocalCommitSignature {
    Pgp(String),
    Ssh,
    Unsupported,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum RestCommitSignatureBoundary {
    RestSupported,
    NativeGitTransportRequired(NativeGitTransportReason),
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct NativeSshCommitSignature {
    pub(super) armored_signature: String,
    pub(super) rest_boundary: RestCommitSignatureBoundary,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum NativeGitTransportReason {
    ConfiguredSshSigning,
    ExistingSshSignature,
}

#[derive(Serialize)]
pub(super) struct GitHubCreateBlobRequest {
    pub(super) content: String,
    pub(super) encoding: &'static str,
}

#[derive(Serialize)]
pub(super) struct GitHubCreateTreeRequest {
    pub(super) tree: Vec<GitHubTreeEntryRequest>,
}

#[derive(Serialize)]
pub(super) struct GitHubTreeEntryRequest {
    pub(super) path: String,
    pub(super) mode: String,
    #[serde(rename = "type")]
    pub(super) kind: String,
    pub(super) sha: Option<String>,
}

#[derive(Serialize)]
pub(super) struct GitHubCreateCommitRequest {
    pub(super) message: String,
    pub(super) tree: String,
    pub(super) parents: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) author: Option<GitHubCommitAuthorRequest>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) committer: Option<GitHubCommitAuthorRequest>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) signature: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(super) struct GitHubCommitAuthorRequest {
    pub(super) name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) date: Option<String>,
}

#[derive(Serialize)]
pub(super) struct GitHubUpdateRefRequest<'a> {
    pub(super) sha: &'a str,
    pub(super) force: bool,
}

#[derive(Deserialize)]
pub(super) struct GitHubObjectShaResponse {
    pub(super) sha: String,
}
