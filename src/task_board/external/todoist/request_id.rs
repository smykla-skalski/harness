use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::move_task::TodoistMoveTaskRequest;
use super::{TaskBoardItem, TaskBoardStatus, TodoistCreateTaskRequest, TodoistUpdateTaskRequest};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum TodoistStatusAction {
    Close,
    Reopen,
}

impl TodoistStatusAction {
    pub(super) const fn for_status(status: TaskBoardStatus) -> Self {
        if matches!(status, TaskBoardStatus::Done) {
            Self::Close
        } else {
            Self::Reopen
        }
    }

    pub(super) fn endpoint(self, external_id: &str) -> String {
        format!("tasks/{external_id}/{}", self.identity())
    }

    const fn identity(self) -> &'static str {
        match self {
            Self::Close => "close",
            Self::Reopen => "reopen",
        }
    }
}

pub(super) enum TodoistRequestIntent<'a> {
    Create {
        item: &'a TaskBoardItem,
        request: &'a TodoistCreateTaskRequest,
    },
    Metadata {
        item: &'a TaskBoardItem,
        external_id: &'a str,
        request: &'a TodoistUpdateTaskRequest,
    },
    Move {
        item: &'a TaskBoardItem,
        external_id: &'a str,
        request: &'a TodoistMoveTaskRequest,
    },
    Status {
        item: &'a TaskBoardItem,
        external_id: &'a str,
        action: TodoistStatusAction,
    },
    Delete {
        item: &'a TaskBoardItem,
        external_id: &'a str,
    },
}

impl TodoistRequestIntent<'_> {
    pub(super) fn request_id(&self) -> String {
        let mut hash = RequestIdHash::default();
        match self {
            Self::Create { item, request } => {
                hash.required("create");
                // Preserve the current local item revision as the create retry
                // boundary until durable provider create keys are wired.
                hash.item_revision(item);
                hash.required(&request.content);
                hash.optional(request.description.as_deref());
                hash.optional(request.project_id.as_deref());
            }
            Self::Move {
                item,
                external_id,
                request,
            } => {
                hash.required("move");
                hash.item_revision(item);
                hash.required(external_id);
                hash.required(&request.project_id);
            }
            Self::Metadata {
                item,
                external_id,
                request,
            } => {
                hash.required("metadata");
                hash.item_revision(item);
                hash.required(external_id);
                hash.optional(request.content.as_deref());
                hash.optional(request.description.as_deref());
            }
            Self::Status {
                item,
                external_id,
                action,
            } => {
                hash.required("status");
                hash.item_revision(item);
                hash.required(external_id);
                hash.required(action.identity());
            }
            Self::Delete { item, external_id } => {
                hash.required("delete");
                hash.item_revision(item);
                hash.required(external_id);
            }
        }
        hash.finish()
    }
}

#[derive(Default)]
struct RequestIdHash {
    hasher: Sha256,
}

impl RequestIdHash {
    fn item_revision(&mut self, item: &TaskBoardItem) {
        self.required(&item.id);
        self.required(&item.updated_at);
    }

    fn required(&mut self, value: &str) {
        self.hasher.update([1]);
        self.hasher.update((value.len() as u64).to_be_bytes());
        self.hasher.update(value.as_bytes());
    }

    fn optional(&mut self, value: Option<&str>) {
        match value {
            Some(value) => self.required(value),
            None => self.hasher.update([0]),
        }
    }

    fn finish(self) -> String {
        let digest = self.hasher.finalize();
        let mut bytes = [0_u8; 16];
        bytes.copy_from_slice(&digest[..16]);
        bytes[6] = (bytes[6] & 0x0f) | 0x50;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        Uuid::from_bytes(bytes).to_string()
    }
}
