// This file used to re-include every src/git source and re-declare GitError
// and GitResult beside them, so the daemon built its own copy of both. Naming
// the owning crate makes a second copy impossible rather than merely absent.
pub use harness_workspace::git::*;
