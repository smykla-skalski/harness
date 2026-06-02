pub(super) fn default_automation_enabled() -> bool {
    true
}

pub(super) fn default_automation_source_app_mode() -> String {
    "allExceptDenied".to_string()
}

pub(super) fn default_true() -> bool {
    true
}

pub(super) fn default_ocr_recognition_level() -> String {
    "accurate".to_string()
}

pub(super) fn default_review_repository_mode() -> String {
    "allConfiguredRepos".to_string()
}

pub(super) fn default_review_result_scope() -> String {
    "all".to_string()
}

pub(super) fn default_review_failure_signal_mode() -> String {
    "liveOrVisual".to_string()
}

pub(super) fn default_review_output_format() -> String {
    "newlineGitHubURLs".to_string()
}
