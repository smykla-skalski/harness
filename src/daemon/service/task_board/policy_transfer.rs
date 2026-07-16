//! Exact policy-canvas bundle dump and atomic import.

use std::collections::HashSet;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    POLICY_TRANSFER_FORMAT, POLICY_TRANSFER_VERSION, PolicyCanvasWorkspaceResponse,
    PolicyTransferBundle, PolicyTransferDumpRequest, PolicyTransferImportRequest,
    PolicyTransferWorkspaceMetadata,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::policy_graph::{
    POLICY_CANVAS_WORKSPACE_VERSION, PolicyCanvasRecord, PolicyCanvasWorkspace, PolicyGraph,
    PolicyGraphMode, PolicyScenario,
};

use super::policy_canvas::{bump_change_policy, feed_gate_cache};
use super::policy_canvas_response::policy_canvas_workspace_response;

#[cfg(test)]
mod tests;

/// Dump every policy with full workspace metadata, or exact selected records
/// without source-workspace metadata.
///
/// # Errors
/// Returns `CliError` when policy state cannot be read, a requested ID is
/// duplicated, or a requested policy does not exist.
pub(crate) async fn dump_policies(
    db: &AsyncDaemonDb,
    request: &PolicyTransferDumpRequest,
) -> Result<PolicyTransferBundle, CliError> {
    let workspace = db
        .load_policy_workspace()
        .await?
        .ok_or_else(|| transfer_error("policy workspace is not initialized".to_string()))?;
    let (policies, metadata) = if request.policy_ids.is_empty() {
        (
            workspace.canvases.clone(),
            Some(workspace_metadata(&workspace)),
        )
    } else {
        (selected_policies(&workspace, &request.policy_ids)?, None)
    };
    Ok(PolicyTransferBundle {
        format: POLICY_TRANSFER_FORMAT.to_string(),
        version: POLICY_TRANSFER_VERSION,
        policies,
        workspace: metadata,
    })
}

/// Validate and atomically merge or replace exact policy canvas records.
///
/// Merge mode upserts by canvas ID while preserving all target workspace
/// metadata and unrelated canvases. Replace-all mode requires source metadata
/// and replaces the complete workspace.
///
/// # Errors
/// Returns `CliError` when the bundle format, records, or metadata are invalid,
/// or when the database write fails.
pub(crate) async fn import_policies(
    db: &AsyncDaemonDb,
    request: &PolicyTransferImportRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    validate_import(request)?;
    let policies = request.bundle.policies.clone();
    let metadata = request.bundle.workspace.clone();
    let replace_all = request.replace_all;
    let (workspace, ()) = db
        .update_policy_workspace(move |target| {
            if replace_all {
                let metadata = metadata.ok_or_else(|| {
                    transfer_error(
                        "replace-all policy import requires workspace metadata".to_string(),
                    )
                })?;
                *target = complete_workspace(metadata, policies);
            } else {
                merge_policies(target, policies);
            }
            validate_workspace(target)?;
            Ok(())
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

fn selected_policies(
    workspace: &PolicyCanvasWorkspace,
    requested_ids: &[String],
) -> Result<Vec<PolicyCanvasRecord>, CliError> {
    let mut selected = Vec::with_capacity(requested_ids.len());
    let mut seen = HashSet::with_capacity(requested_ids.len());
    for policy_id in requested_ids {
        validate_identifier(policy_id, "requested policy ID")?;
        if !seen.insert(policy_id.as_str()) {
            return Err(transfer_error(format!(
                "duplicate requested policy ID '{policy_id}'"
            )));
        }
        let policy = workspace
            .canvas(policy_id)
            .ok_or_else(|| transfer_error(format!("unknown policy canvas '{policy_id}'")))?;
        selected.push(policy.clone());
    }
    Ok(selected)
}

fn validate_import(request: &PolicyTransferImportRequest) -> Result<(), CliError> {
    let bundle = &request.bundle;
    if bundle.format != POLICY_TRANSFER_FORMAT {
        return Err(transfer_error(format!(
            "unsupported policy transfer format '{}'",
            bundle.format
        )));
    }
    if bundle.version != POLICY_TRANSFER_VERSION {
        return Err(transfer_error(format!(
            "unsupported policy transfer version {}; expected {POLICY_TRANSFER_VERSION}",
            bundle.version
        )));
    }
    validate_policies(&bundle.policies)?;
    if request.replace_all {
        validate_replace_all(bundle)?;
    }
    Ok(())
}

fn validate_policies(policies: &[PolicyCanvasRecord]) -> Result<(), CliError> {
    if policies.is_empty() {
        return Err(transfer_error(
            "policy transfer bundle contains no policies".to_string(),
        ));
    }
    let mut ids = HashSet::with_capacity(policies.len());
    for policy in policies {
        validate_identifier(&policy.id, "policy ID")?;
        if !ids.insert(policy.id.as_str()) {
            return Err(transfer_error(format!(
                "duplicate policy ID '{}' in transfer bundle",
                policy.id
            )));
        }
        validate_document(&policy.id, "document", &policy.document)?;
        validate_live_document(policy)?;
    }
    Ok(())
}

fn validate_document(policy_id: &str, field: &str, document: &PolicyGraph) -> Result<(), CliError> {
    if i64::try_from(document.revision).is_err() {
        return Err(transfer_error(format!(
            "policy '{policy_id}' {field} revision {} exceeds the database limit",
            document.revision
        )));
    }
    let report = document.validate();
    if !report.is_valid() {
        return Err(transfer_error(format!(
            "policy '{policy_id}' {field} validation failed with {} issue(s)",
            report.issues.len()
        )));
    }
    validate_layout(policy_id, field, document)
}

fn validate_layout(policy_id: &str, field: &str, document: &PolicyGraph) -> Result<(), CliError> {
    let node_ids: HashSet<&str> = document.nodes.iter().map(|node| node.id.as_str()).collect();
    let mut seen = HashSet::with_capacity(document.layout.nodes.len());
    let mut actual = Vec::with_capacity(document.layout.nodes.len());
    for layout in &document.layout.nodes {
        let node_id = layout.node_id.as_str();
        if !node_ids.contains(node_id) {
            return Err(transfer_error(format!(
                "policy '{policy_id}' {field} layout references unknown node '{node_id}'"
            )));
        }
        if !seen.insert(node_id) {
            return Err(transfer_error(format!(
                "policy '{policy_id}' {field} layout repeats node '{node_id}'"
            )));
        }
        actual.push(node_id);
    }
    let expected: Vec<&str> = document
        .nodes
        .iter()
        .map(|node| node.id.as_str())
        .filter(|node_id| seen.contains(node_id))
        .collect();
    if actual != expected {
        return Err(transfer_error(format!(
            "policy '{policy_id}' {field} layout entries must follow document node order"
        )));
    }
    Ok(())
}

fn validate_live_document(policy: &PolicyCanvasRecord) -> Result<(), CliError> {
    if policy.live_document.is_some() != policy.live_updated_at.is_some() {
        return Err(transfer_error(format!(
            "policy '{}' live_document and live_updated_at must either both be present or both be absent",
            policy.id
        )));
    }
    let Some(live_document) = &policy.live_document else {
        return Ok(());
    };
    if live_document.mode != PolicyGraphMode::Enforced {
        return Err(transfer_error(format!(
            "policy '{}' live_document must be enforced",
            policy.id
        )));
    }
    validate_document(&policy.id, "live_document", live_document)
}

fn validate_replace_all(bundle: &PolicyTransferBundle) -> Result<(), CliError> {
    let metadata = bundle.workspace.as_ref().ok_or_else(|| {
        transfer_error("replace-all policy import requires workspace metadata".to_string())
    })?;
    if metadata.schema_version != POLICY_CANVAS_WORKSPACE_VERSION {
        return Err(transfer_error(format!(
            "unsupported policy workspace schema version {}; expected {POLICY_CANVAS_WORKSPACE_VERSION}",
            metadata.schema_version
        )));
    }
    validate_identifier(&metadata.active_canvas_id, "replace-all active policy ID")?;
    validate_scenarios(&metadata.scenarios)?;
    if bundle
        .policies
        .iter()
        .all(|policy| policy.id != metadata.active_canvas_id)
    {
        return Err(transfer_error(format!(
            "replace-all active policy '{}' is absent from bundle",
            metadata.active_canvas_id
        )));
    }
    Ok(())
}

fn validate_workspace(workspace: &PolicyCanvasWorkspace) -> Result<(), CliError> {
    if workspace.schema_version != POLICY_CANVAS_WORKSPACE_VERSION {
        return Err(transfer_error(format!(
            "unsupported policy workspace schema version {}; expected {POLICY_CANVAS_WORKSPACE_VERSION}",
            workspace.schema_version
        )));
    }
    validate_identifier(&workspace.active_canvas_id, "active policy ID")?;
    if workspace.canvas(&workspace.active_canvas_id).is_none() {
        return Err(transfer_error(format!(
            "active policy '{}' is absent from workspace",
            workspace.active_canvas_id
        )));
    }
    validate_policies(&workspace.canvases)?;
    validate_unique_policy_roles(&workspace.canvases)?;
    validate_scenarios(&workspace.scenarios)
}

fn validate_unique_policy_roles(policies: &[PolicyCanvasRecord]) -> Result<(), CliError> {
    let roles = [
        (
            "manual OCR paste",
            policies
                .iter()
                .filter(|policy| policy.is_manual_ocr_paste_canvas)
                .count(),
        ),
        (
            "review text paste dry run",
            policies
                .iter()
                .filter(|policy| policy.is_review_text_paste_dry_run_canvas)
                .count(),
        ),
        (
            "review screenshot extraction",
            policies
                .iter()
                .filter(|policy| policy.is_review_screenshot_extraction_canvas)
                .count(),
        ),
    ];
    for (role, count) in roles {
        if count > 1 {
            return Err(transfer_error(format!(
                "policy workspace contains {count} canvases with the '{role}' role"
            )));
        }
    }
    Ok(())
}

fn validate_scenarios(scenarios: &[PolicyScenario]) -> Result<(), CliError> {
    let mut ids = HashSet::with_capacity(scenarios.len());
    for scenario in scenarios {
        validate_identifier(&scenario.id, "policy scenario ID")?;
        validate_identifier(
            &scenario.name,
            &format!("policy scenario '{}' name", scenario.id),
        )?;
        if !ids.insert(scenario.id.as_str()) {
            return Err(transfer_error(format!(
                "duplicate policy scenario ID '{}'",
                scenario.id
            )));
        }
    }
    Ok(())
}

fn validate_identifier(value: &str, label: &str) -> Result<(), CliError> {
    if value.trim().is_empty() {
        return Err(transfer_error(format!("{label} must not be blank")));
    }
    if value.trim() != value {
        return Err(transfer_error(format!(
            "{label} must not have leading or trailing whitespace"
        )));
    }
    Ok(())
}

fn merge_policies(target: &mut PolicyCanvasWorkspace, policies: Vec<PolicyCanvasRecord>) {
    for policy in policies {
        if let Some(existing) = target
            .canvases
            .iter_mut()
            .find(|existing| existing.id == policy.id)
        {
            *existing = policy;
        } else {
            target.canvases.push(policy);
        }
    }
}

fn complete_workspace(
    metadata: PolicyTransferWorkspaceMetadata,
    policies: Vec<PolicyCanvasRecord>,
) -> PolicyCanvasWorkspace {
    PolicyCanvasWorkspace {
        schema_version: metadata.schema_version,
        active_canvas_id: metadata.active_canvas_id,
        canvases: policies,
        global_policy_enforcement_enabled: metadata.global_policy_enforcement_enabled,
        manual_ocr_paste_canvas_deleted: metadata.manual_ocr_paste_canvas_deleted,
        review_text_paste_dry_run_canvas_deleted: metadata.review_text_paste_dry_run_canvas_deleted,
        review_screenshot_extraction_canvas_deleted: metadata
            .review_screenshot_extraction_canvas_deleted,
        scenarios: metadata.scenarios,
        scenarios_seeded: metadata.scenarios_seeded,
        spawn_requires_live_policy: metadata.spawn_requires_live_policy,
        spawn_kill_switch: metadata.spawn_kill_switch,
    }
}

fn workspace_metadata(workspace: &PolicyCanvasWorkspace) -> PolicyTransferWorkspaceMetadata {
    PolicyTransferWorkspaceMetadata {
        schema_version: workspace.schema_version,
        active_canvas_id: workspace.active_canvas_id.clone(),
        global_policy_enforcement_enabled: workspace.global_policy_enforcement_enabled,
        manual_ocr_paste_canvas_deleted: workspace.manual_ocr_paste_canvas_deleted,
        review_text_paste_dry_run_canvas_deleted: workspace
            .review_text_paste_dry_run_canvas_deleted,
        review_screenshot_extraction_canvas_deleted: workspace
            .review_screenshot_extraction_canvas_deleted,
        scenarios: workspace.scenarios.clone(),
        scenarios_seeded: workspace.scenarios_seeded,
        spawn_requires_live_policy: workspace.spawn_requires_live_policy,
        spawn_kill_switch: workspace.spawn_kill_switch,
    }
}

fn transfer_error(detail: String) -> CliError {
    CliErrorKind::invalid_transition(detail).into()
}
