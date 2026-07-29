use super::ReviewCheckConclusion;

pub(super) fn is_failed_check_conclusion(conclusion: ReviewCheckConclusion) -> bool {
    matches!(
        conclusion,
        ReviewCheckConclusion::Failure
            | ReviewCheckConclusion::Cancelled
            | ReviewCheckConclusion::TimedOut
            | ReviewCheckConclusion::ActionRequired
            | ReviewCheckConclusion::StartupFailure
    )
}

pub(super) fn normalized_details_url(details_url: Option<String>) -> Option<String> {
    let trimmed = details_url?.trim().to_string();
    if trimmed.is_empty() {
        return None;
    }
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("https://") || lower.starts_with("http://") {
        Some(trimmed)
    } else {
        None
    }
}
