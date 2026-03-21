use super::*;

#[test]
fn compute_verdict_all_passed() {
    assert_eq!(compute_verdict_from_counts(5, 0, 0), Some(Verdict::Pass));
}

#[test]
fn compute_verdict_passed_and_skipped() {
    assert_eq!(compute_verdict_from_counts(3, 0, 2), Some(Verdict::Pass));
}

#[test]
fn compute_verdict_any_failed() {
    assert_eq!(compute_verdict_from_counts(3, 1, 0), Some(Verdict::Fail));
}

#[test]
fn compute_verdict_all_skipped() {
    assert_eq!(compute_verdict_from_counts(0, 0, 5), Some(Verdict::Pass));
}

#[test]
fn compute_verdict_no_groups() {
    assert_eq!(compute_verdict_from_counts(0, 0, 0), None);
}
