use std::path::Path;

use super::manual_git_failure;
use crate::git::GitError;

#[test]
fn bounded_validation_is_manual_but_promotion_ambiguity_is_retryable() {
    let repository = Path::new("/frozen/result-import");

    assert!(manual_git_failure(&GitError::unsafe_state(
        repository,
        "Git operation exceeded its resource contract",
    )));
    assert!(!manual_git_failure(&GitError::mutation(
        repository,
        "validated pack promotion was interrupted",
    )));
}
