use super::*;
use crate::task_board::external::ExternalProvider;

fn repository() -> GitHubRepository {
    GitHubRepository {
        owner: "smykla-skalski".into(),
        repo: "harness".into(),
    }
}

const CHILD_BODY: &str = "## Problem\n\nItems have no relationship.\n\n## Expected outcome\n\n- An item can be given a parent\n\nPart of #312\n";

const UMBRELLA_BODY: &str = "## Child issues\n\n- [x] #313 link items to a parent item\n- [ ] #314 record what kind of item each item is\n- [ ] #316 import issue hierarchy from GitHub\n";

#[test]
fn parent_reference_in_body_finds_a_same_repo_tracking_issue() {
    let reference =
        parent_reference_in_body(&repository(), CHILD_BODY).expect("body names a tracking issue");
    assert_eq!(reference.provider, ExternalProvider::GitHub);
    assert_eq!(reference.external_id, "smykla-skalski/harness#312");
}

#[test]
fn parent_reference_in_body_resolves_a_cross_repo_tracking_issue() {
    let body = "Fixes the bug.\n\nPart of other-owner/other-repo#42\n";
    let reference =
        parent_reference_in_body(&repository(), body).expect("body names a cross-repo parent");
    assert_eq!(reference.external_id, "other-owner/other-repo#42");
}

#[test]
fn parent_reference_in_body_is_none_without_a_tracking_phrase() {
    let body = "Just a regular issue with no tracking relationship, closes #99 eventually.";
    assert!(parent_reference_in_body(&repository(), body).is_none());
}

#[test]
fn parent_reference_in_body_ignores_part_of_without_an_issue_number() {
    let body = "This is part of the larger redesign effort described elsewhere.";
    assert!(parent_reference_in_body(&repository(), body).is_none());
}

#[test]
fn body_lists_child_issues_detects_a_tracking_checklist() {
    assert!(body_lists_child_issues(UMBRELLA_BODY));
}

#[test]
fn body_lists_child_issues_ignores_unrelated_checkboxes() {
    let body = "## Test plan\n\n- [ ] I have tested this locally\n- [x] Docs updated\n";
    assert!(!body_lists_child_issues(body));
}

#[test]
fn body_lists_child_issues_is_false_for_a_leaf_issue_body() {
    assert!(!body_lists_child_issues(CHILD_BODY));
}
