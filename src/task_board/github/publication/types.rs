use crate::task_board::TaskBoardGitRuntimeProfile;

pub(super) struct LocalBranchSnapshot {
    pub(super) head_tree_sha: String,
    pub(super) commit_message: String,
    pub(super) author: LocalCommitAuthor,
    pub(super) committer: LocalCommitAuthor,
    pub(super) profile: TaskBoardGitRuntimeProfile,
    pub(super) existing_signature: Option<LocalCommitSignature>,
}

pub(super) struct LocalCommitAuthor {
    pub(super) git_actor: String,
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
pub(super) struct NativeSshCommitObject {
    pub(super) commit_payload: Vec<u8>,
    pub(super) signature: NativeSshCommitSignature,
    pub(super) unsigned_payload: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum NativeGitTransportReason {
    ConfiguredSshSigning,
    ExistingSshSignature,
}
