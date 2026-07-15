//! Versioned wire contract for exact policy-canvas transfer bundles.

use serde::{Deserialize, Serialize};

use crate::task_board::policy_graph::{PolicyCanvasRecord, PolicyScenario};

pub const POLICY_TRANSFER_FORMAT: &str = "harness-policy-transfer";
pub const POLICY_TRANSFER_VERSION: u32 = 1;

/// Complete non-canvas state needed to replace a policy workspace exactly.
#[expect(
    clippy::struct_excessive_bools,
    reason = "transfer metadata mirrors independent persisted workspace flags"
)]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PolicyTransferWorkspaceMetadata {
    pub schema_version: u32,
    pub active_canvas_id: String,
    pub global_policy_enforcement_enabled: bool,
    pub manual_ocr_paste_canvas_deleted: bool,
    pub review_text_paste_dry_run_canvas_deleted: bool,
    pub review_screenshot_extraction_canvas_deleted: bool,
    pub scenarios: Vec<PolicyScenario>,
    pub scenarios_seeded: bool,
    pub spawn_requires_live_policy: bool,
    pub spawn_kill_switch: bool,
}

/// Versioned envelope carrying one or many exact policy canvas records.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PolicyTransferBundle {
    pub format: String,
    pub version: u32,
    pub policies: Vec<PolicyCanvasRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<PolicyTransferWorkspaceMetadata>,
}

/// Select policies for a dump. Empty `policy_ids` dumps every policy and full
/// workspace metadata.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyTransferDumpRequest {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_ids: Vec<String>,
}

/// Import one or many exact policy records, either by merge/upsert or by full
/// workspace replacement.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PolicyTransferImportRequest {
    pub bundle: PolicyTransferBundle,
    #[serde(default)]
    pub replace_all: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dump_request_round_trips_as_json_without_losing_ids() {
        let request = PolicyTransferDumpRequest {
            policy_ids: vec!["policy,one".to_string(), " policy-two ".to_string()],
        };

        let encoded = serde_json::to_string(&request).expect("encode request");
        assert_eq!(
            serde_json::from_str::<PolicyTransferDumpRequest>(&encoded).expect("decode request"),
            request,
        );
    }

    #[test]
    fn empty_dump_request_omits_policy_ids() {
        assert_eq!(
            serde_json::to_value(PolicyTransferDumpRequest::default())
                .expect("encode empty request"),
            serde_json::json!({}),
        );
    }
}
