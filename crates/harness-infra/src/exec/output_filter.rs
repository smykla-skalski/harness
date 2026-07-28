/// Check if the line is an error or warning that should surface verbatim.
pub(super) fn is_error_or_warning(lower: &str) -> bool {
    lower.starts_with("error")
        || lower.starts_with("warning")
        || lower.starts_with("fatal")
        || lower.contains("err:")
        || lower.contains("failed")
        || lower.contains("timed out")
}

/// Match k3d checkpoint patterns to harness progress messages.
pub(super) fn match_k3d_checkpoint(lower: &str) -> Option<&'static str> {
    if lower.contains("preparing nodes") {
        return Some("k3d: preparing nodes");
    }
    if lower.contains("creating node") {
        return Some("k3d: creating nodes");
    }
    if lower.contains("pulling image") {
        return Some("k3d: pulling images");
    }
    if lower.contains("importing image") {
        return Some("k3d: importing images");
    }
    if lower.contains("loading images") || lower.contains("importing images into") {
        return Some("k3d: loading images into cluster");
    }
    if lower.contains("successfully created") || lower.contains("cluster created") {
        return Some("k3d: cluster created");
    }
    None
}

/// Match helm checkpoint patterns to harness progress messages.
pub(super) fn match_helm_checkpoint(lower: &str) -> Option<&'static str> {
    if lower.contains("release") && lower.contains("deployed") {
        return Some("helm: release deployed");
    }

    if lower.contains("rollback") {
        return Some("helm: rollback triggered");
    }

    if (lower.contains("install") || lower.contains("upgrade"))
        && lower.contains("helm")
        && !lower.contains("coalesce")
    {
        return Some("helm: installing release");
    }

    if lower.contains("manifest") && lower.contains("render") {
        return Some("helm: rendering manifests");
    }

    None
}

/// Match kubectl checkpoint patterns to harness progress messages.
pub(super) fn match_kubectl_checkpoint(lower: &str, trimmed: &str) -> Option<String> {
    if lower.contains("condition met") {
        return Some("kubectl: condition met".into());
    }

    if lower.contains("rollout") && lower.contains("complete") {
        return Some("kubectl: rollout complete".into());
    }

    if lower.contains("waiting for") && lower.contains("rollout") {
        return Some("kubectl: waiting for rollout".into());
    }

    if lower.contains("waiting for") && lower.contains("condition") {
        return Some(filter_kubectl_wait_detail(trimmed));
    }

    if lower.contains("deployment") && lower.contains("successfully rolled out") {
        return Some("kubectl: deployment rolled out".into());
    }

    if lower.contains("pod/") && lower.contains("running") {
        return Some("kubectl: pod running".into());
    }

    None
}

/// Match docker compose checkpoint patterns to harness progress messages.
pub(super) fn match_compose_checkpoint(lower: &str) -> Option<&'static str> {
    if !lower.contains("container") {
        return None;
    }

    if lower.contains("started") {
        return Some("compose: container started");
    }

    if lower.contains("healthy") {
        return Some("compose: container healthy");
    }

    if lower.contains("waiting") {
        return Some("compose: waiting for container health");
    }

    if lower.contains("created") {
        return Some("compose: container created");
    }

    None
}

/// Map a subprocess stderr line to a harness checkpoint message.
///
/// Returns `Some(message)` for lines that indicate meaningful progress,
/// translated into harness's own format. Raw subprocess output is never
/// passed through - only our own summary messages or actual errors.
pub(crate) fn filter_progress_line(line: &str) -> Option<String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    let lower = trimmed.to_lowercase();

    if is_error_or_warning(&lower) {
        return Some(trimmed.to_string());
    }

    if let Some(message) = match_k3d_checkpoint(&lower) {
        return Some(message.into());
    }
    if let Some(message) = match_helm_checkpoint(&lower) {
        return Some(message.into());
    }
    if let Some(message) = match_kubectl_checkpoint(&lower, trimmed) {
        return Some(message);
    }
    if let Some(message) = match_compose_checkpoint(&lower) {
        return Some(message.into());
    }

    // everything else (Docker BuildKit layers, verbose helm output,
    // kubectl apply lines, etc.) is captured but not printed
    None
}

/// Extract a readable detail from kubectl wait lines.
///
/// Lines like "Waiting for condition=Ready on pod/kuma-cp-xyz" become
/// "kubectl: waiting for condition=Ready on pod/kuma-cp-xyz".
pub(super) fn filter_kubectl_wait_detail(line: &str) -> String {
    let lower = line.to_lowercase();
    // Try to extract "condition=X" and the resource name
    if let Some(condition_start) = lower.find("condition") {
        let remainder = &line[condition_start..];
        let detail = remainder
            .split_whitespace()
            .take(3) // "condition=Ready on pod/name"
            .collect::<Vec<_>>()
            .join(" ");
        return format!("kubectl: waiting for {detail}");
    }
    "kubectl: waiting for condition".into()
}
