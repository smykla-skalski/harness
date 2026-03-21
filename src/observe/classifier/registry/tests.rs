use super::*;
use std::collections::HashSet;

#[test]
fn registry_covers_all_codes() {
    for code in IssueCode::ALL {
        assert!(
            issue_code_meta(*code).is_some(),
            "IssueCode::{code:?} is missing from the registry"
        );
    }
}

#[test]
fn registry_has_no_duplicates() {
    let mut seen = HashSet::new();
    for entry in ISSUE_CODE_REGISTRY.as_ref() {
        assert!(
            seen.insert(entry.code),
            "IssueCode::{:?} appears more than once in the registry",
            entry.code
        );
    }
}

#[test]
fn registry_count_matches_all_codes() {
    assert_eq!(
        ISSUE_CODE_REGISTRY.len(),
        IssueCode::ALL.len(),
        "Registry has {} entries but IssueCode::ALL has {}",
        ISSUE_CODE_REGISTRY.len(),
        IssueCode::ALL.len()
    );
}

#[test]
fn issue_owner_display() {
    assert_eq!(IssueOwner::Harness.to_string(), "harness");
    assert_eq!(IssueOwner::Skill.to_string(), "skill");
    assert_eq!(IssueOwner::Product.to_string(), "product");
    assert_eq!(IssueOwner::Model.to_string(), "model");
}

#[test]
fn all_descriptions_non_empty() {
    for entry in ISSUE_CODE_REGISTRY.as_ref() {
        assert!(
            !entry.description.is_empty(),
            "IssueCode::{:?} has an empty description",
            entry.code
        );
    }
}
