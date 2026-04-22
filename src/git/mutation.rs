#![allow(dead_code)]

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LinkedWorktreeBackend {
    Git2,
}

pub(crate) const LINKED_WORKTREE_BACKEND: LinkedWorktreeBackend = LinkedWorktreeBackend::Git2;

#[cfg(test)]
mod tests {
    use super::{LINKED_WORKTREE_BACKEND, LinkedWorktreeBackend};

    #[test]
    fn linked_worktree_backend_defaults_to_git2() {
        assert_eq!(LINKED_WORKTREE_BACKEND, LinkedWorktreeBackend::Git2);
    }
}
