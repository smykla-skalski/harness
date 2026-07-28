use super::PolicyCanvasPoint;

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

pub(super) fn default_policy_graph_zoom() -> f64 {
    1.0
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde skip_serializing_if passes the field by reference"
)]
pub(super) fn is_default_policy_graph_zoom(zoom: &f64) -> bool {
    zoom.to_bits() == default_policy_graph_zoom().to_bits()
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde skip_serializing_if passes the field by reference"
)]
pub(super) fn is_default_policy_canvas_point(point: &PolicyCanvasPoint) -> bool {
    *point == PolicyCanvasPoint::default()
}
