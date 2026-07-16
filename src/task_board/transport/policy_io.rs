use std::collections::HashSet;
use std::fmt::Display;
use std::fs;
use std::io::{self, Read};

use clap::Args;
use serde_json::Value;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::{
    POLICY_TRANSFER_FORMAT, POLICY_TRANSFER_VERSION, PolicyTransferBundle,
    PolicyTransferDumpRequest, PolicyTransferImportRequest, PolicyTransferWorkspaceMetadata,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::policy_graph::PolicyCanvasRecord;

use super::{daemon_client, print_json};

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPolicyDumpArgs {
    /// Limit the dump to one or more policy canvases.
    #[arg(long = "canvas-id")]
    pub canvas_ids: Vec<String>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPolicyImportArgs {
    /// JSON file to import; use `-` for standard input.
    #[arg(value_name = "INPUT", default_value = "-")]
    pub inputs: Vec<String>,
    /// Replace the whole policy workspace using bundle metadata.
    #[arg(long)]
    pub replace_all: bool,
    /// Print the daemon response as JSON.
    #[arg(long)]
    pub json: bool,
}

impl Execute for TaskBoardPolicyDumpArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let bundle = daemon_client()?.dump_policy_transfer(&PolicyTransferDumpRequest {
            policy_ids: self.canvas_ids.clone(),
        })?;
        print_json(&bundle)?;
        Ok(0)
    }
}

impl Execute for TaskBoardPolicyImportArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let mut stdin = io::stdin().lock();
        let bundle = decode_policy_inputs(&self.inputs, &mut stdin)?;
        validate_replace_all(self.replace_all, &bundle)?;
        let policy_count = bundle.policies.len();
        let response = daemon_client()?.import_policy_transfer(&PolicyTransferImportRequest {
            bundle,
            replace_all: self.replace_all,
        })?;
        if self.json {
            print_json(&response)?;
        } else {
            print_import_summary(policy_count, self.replace_all);
        }
        Ok(0)
    }
}

fn decode_policy_inputs<R: Read>(
    inputs: &[String],
    stdin: &mut R,
) -> Result<PolicyTransferBundle, CliError> {
    let mut accumulator = PolicyInputAccumulator::default();
    let mut stdin_seen = false;
    for input in inputs {
        let contents = read_policy_input(input, stdin, &mut stdin_seen)?;
        accumulator.absorb_json(input, &contents)?;
    }
    accumulator.finish()
}

fn read_policy_input<R: Read>(
    input: &str,
    stdin: &mut R,
    stdin_seen: &mut bool,
) -> Result<String, CliError> {
    if input != "-" {
        return fs::read_to_string(input).map_err(|error| {
            CliErrorKind::workflow_io(format!("failed to read policy input '{input}': {error}"))
                .into()
        });
    }
    if *stdin_seen {
        return Err(CliErrorKind::workflow_parse(
            "standard input may be specified only once".to_string(),
        )
        .into());
    }
    *stdin_seen = true;
    let mut contents = String::new();
    stdin.read_to_string(&mut contents).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "failed to read policy input from stdin: {error}"
        )))
    })?;
    Ok(contents)
}

#[derive(Default)]
struct PolicyInputAccumulator {
    policies: Vec<PolicyCanvasRecord>,
    policy_ids: HashSet<String>,
    workspace: Option<PolicyTransferWorkspaceMetadata>,
}

impl PolicyInputAccumulator {
    fn absorb_json(&mut self, label: &str, contents: &str) -> Result<(), CliError> {
        let value: Value = serde_json::from_str(contents)
            .map_err(|error| policy_parse_error(label, error.to_string()))?;
        match value {
            Value::Array(_) => {
                let policies: Vec<PolicyCanvasRecord> = serde_json::from_value(value)
                    .map_err(|error| policy_parse_error(label, error.to_string()))?;
                self.absorb_policies(label, policies)
            }
            Value::Object(ref object) if looks_like_bundle(object) => {
                let bundle: PolicyTransferBundle = serde_json::from_value(value)
                    .map_err(|error| policy_parse_error(label, error.to_string()))?;
                self.absorb_bundle(label, bundle)
            }
            Value::Object(_) => {
                let policy: PolicyCanvasRecord = serde_json::from_value(value)
                    .map_err(|error| policy_parse_error(label, error.to_string()))?;
                self.absorb_policies(label, vec![policy])
            }
            _ => Err(policy_parse_error(
                label,
                "expected a transfer bundle, policy object, or policy array",
            )),
        }
    }

    fn absorb_bundle(&mut self, label: &str, bundle: PolicyTransferBundle) -> Result<(), CliError> {
        if bundle.format != POLICY_TRANSFER_FORMAT || bundle.version != POLICY_TRANSFER_VERSION {
            return Err(policy_parse_error(
                label,
                format!(
                    "unsupported transfer format '{}'/version {}; expected '{POLICY_TRANSFER_FORMAT}'/version {POLICY_TRANSFER_VERSION}",
                    bundle.format, bundle.version
                ),
            ));
        }
        if let Some(workspace) = bundle.workspace
            && self.workspace.replace(workspace).is_some()
        {
            return Err(CliErrorKind::workflow_parse(
                "multiple policy inputs contain workspace metadata".to_string(),
            )
            .into());
        }
        self.absorb_policies(label, bundle.policies)
    }

    fn absorb_policies(
        &mut self,
        label: &str,
        policies: Vec<PolicyCanvasRecord>,
    ) -> Result<(), CliError> {
        for policy in policies {
            if policy.id.trim().is_empty() {
                return Err(policy_parse_error(label, "policy id cannot be empty"));
            }
            if !self.policy_ids.insert(policy.id.clone()) {
                return Err(CliErrorKind::workflow_parse(format!(
                    "duplicate policy id '{}' across import inputs",
                    policy.id
                ))
                .into());
            }
            self.policies.push(policy);
        }
        Ok(())
    }

    fn finish(self) -> Result<PolicyTransferBundle, CliError> {
        if self.policies.is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "policy import contains no policies".to_string(),
            )
            .into());
        }
        Ok(PolicyTransferBundle {
            format: POLICY_TRANSFER_FORMAT.to_string(),
            version: POLICY_TRANSFER_VERSION,
            policies: self.policies,
            workspace: self.workspace,
        })
    }
}

fn looks_like_bundle(object: &serde_json::Map<String, Value>) -> bool {
    object.contains_key("format")
        || object.contains_key("version")
        || object.contains_key("policies")
        || object.contains_key("workspace")
}

fn validate_replace_all(replace_all: bool, bundle: &PolicyTransferBundle) -> Result<(), CliError> {
    if replace_all && bundle.workspace.is_none() {
        return Err(CliErrorKind::workflow_parse(
            "--replace-all requires workspace metadata from a transfer bundle".to_string(),
        )
        .into());
    }
    Ok(())
}

fn policy_parse_error(label: &str, detail: impl Display) -> CliError {
    CliErrorKind::workflow_parse(format!("invalid policy input '{label}': {detail}")).into()
}

fn print_import_summary(policy_count: usize, replace_all: bool) {
    let noun = if policy_count == 1 {
        "policy"
    } else {
        "policies"
    };
    if replace_all {
        println!("replaced policy workspace with {policy_count} {noun}");
    } else {
        println!("imported {policy_count} {noun}");
    }
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use tempfile::tempdir;

    use super::*;
    use crate::task_board::policy_graph::PolicyCanvasWorkspace;

    #[test]
    fn decoder_accepts_single_policy_from_stdin() {
        let policy = test_policy("canvas-one");
        let json = serde_json::to_vec(&policy).expect("serialize policy");
        let bundle = decode_policy_inputs(&["-".to_string()], &mut Cursor::new(json))
            .expect("decode stdin policy");

        assert_eq!(bundle.policies, [policy]);
        assert!(bundle.workspace.is_none());
        assert_eq!(bundle.format, POLICY_TRANSFER_FORMAT);
        assert_eq!(bundle.version, POLICY_TRANSFER_VERSION);
    }

    #[test]
    fn decoder_combines_file_array_and_stdin_policy() {
        let directory = tempdir().expect("create temp directory");
        let path = directory.path().join("policies.json");
        let first = test_policy("canvas-one");
        let second = test_policy("canvas-two");
        let third = test_policy("canvas-three");
        fs::write(
            &path,
            serde_json::to_vec(&vec![first, second]).expect("serialize policy array"),
        )
        .expect("write policy array");
        let stdin = serde_json::to_vec(&third).expect("serialize stdin policy");
        let inputs = vec![path.display().to_string(), "-".to_string()];

        let bundle =
            decode_policy_inputs(&inputs, &mut Cursor::new(stdin)).expect("decode combined inputs");

        assert_eq!(bundle.policies.len(), 3);
        assert_eq!(bundle.policies[2].id, "canvas-three");
    }

    #[test]
    fn decoder_accepts_complete_bundle_and_preserves_workspace() {
        let source = test_bundle("canvas-one", true);
        let json = serde_json::to_vec(&source).expect("serialize bundle");

        let decoded = decode_policy_inputs(&["-".to_string()], &mut Cursor::new(json))
            .expect("decode bundle");

        assert_eq!(decoded, source);
    }

    #[test]
    fn decoder_rejects_invalid_contract_and_malformed_json() {
        let mut invalid_format = test_bundle("canvas-one", false);
        invalid_format.format = "other-format".to_string();
        let json = serde_json::to_vec(&invalid_format).expect("serialize invalid bundle");
        assert!(decode_policy_inputs(&["-".to_string()], &mut Cursor::new(json)).is_err());

        let mut invalid_version = test_bundle("canvas-one", false);
        invalid_version.version += 1;
        let json = serde_json::to_vec(&invalid_version).expect("serialize invalid bundle");
        assert!(decode_policy_inputs(&["-".to_string()], &mut Cursor::new(json)).is_err());

        assert!(decode_policy_inputs(&["-".to_string()], &mut Cursor::new(b"{".to_vec())).is_err());
    }

    #[test]
    fn decoder_reports_missing_input_file() {
        let directory = tempdir().expect("create temp directory");
        let path = directory.path().join("missing-policy.json");

        assert!(
            decode_policy_inputs(
                &[path.display().to_string()],
                &mut Cursor::new(Vec::<u8>::new()),
            )
            .is_err()
        );
    }

    #[test]
    fn decoder_rejects_empty_and_duplicate_policy_ids() {
        let empty = serde_json::to_vec(&Vec::<PolicyCanvasRecord>::new())
            .expect("serialize empty policy array");
        assert!(decode_policy_inputs(&["-".to_string()], &mut Cursor::new(empty)).is_err());

        let duplicate = vec![test_policy("same-id"), test_policy("same-id")];
        let json = serde_json::to_vec(&duplicate).expect("serialize duplicate policies");
        assert!(decode_policy_inputs(&["-".to_string()], &mut Cursor::new(json)).is_err());

        let blank = serde_json::to_vec(&test_policy("  ")).expect("serialize blank policy id");
        assert!(decode_policy_inputs(&["-".to_string()], &mut Cursor::new(blank)).is_err());
    }

    #[test]
    fn decoder_rejects_stdin_more_than_once() {
        let json = serde_json::to_vec(&test_policy("canvas-one")).expect("serialize policy");
        assert!(
            decode_policy_inputs(&["-".to_string(), "-".to_string()], &mut Cursor::new(json))
                .is_err()
        );
    }

    #[test]
    fn decoder_rejects_multiple_workspace_metadata_blocks() {
        let mut accumulator = PolicyInputAccumulator::default();
        let first = test_bundle("canvas-one", true);
        let second = test_bundle("canvas-two", true);

        accumulator
            .absorb_json(
                "first",
                &serde_json::to_string(&first).expect("serialize first bundle"),
            )
            .expect("decode first bundle");
        assert!(
            accumulator
                .absorb_json(
                    "second",
                    &serde_json::to_string(&second).expect("serialize second bundle"),
                )
                .is_err()
        );
    }

    #[test]
    fn replace_all_requires_workspace_metadata() {
        let bundle = PolicyTransferBundle {
            format: POLICY_TRANSFER_FORMAT.to_string(),
            version: POLICY_TRANSFER_VERSION,
            policies: vec![test_policy("canvas-one")],
            workspace: None,
        };
        assert!(validate_replace_all(true, &bundle).is_err());
        assert!(validate_replace_all(false, &bundle).is_ok());

        let bundle = test_bundle("canvas-one", true);
        assert!(validate_replace_all(true, &bundle).is_ok());
    }

    fn test_policy(id: &str) -> PolicyCanvasRecord {
        let mut workspace = PolicyCanvasWorkspace::seeded();
        let mut policy = workspace.canvases.remove(0);
        policy.id = id.to_string();
        policy
    }

    fn test_bundle(id: &str, include_workspace: bool) -> PolicyTransferBundle {
        let policy = test_policy(id);
        let workspace = include_workspace.then(|| test_metadata(id));
        PolicyTransferBundle {
            format: POLICY_TRANSFER_FORMAT.to_string(),
            version: POLICY_TRANSFER_VERSION,
            policies: vec![policy],
            workspace,
        }
    }

    fn test_metadata(active_canvas_id: &str) -> PolicyTransferWorkspaceMetadata {
        let workspace = PolicyCanvasWorkspace::seeded();
        PolicyTransferWorkspaceMetadata {
            schema_version: workspace.schema_version,
            active_canvas_id: active_canvas_id.to_string(),
            global_policy_enforcement_enabled: workspace.global_policy_enforcement_enabled,
            manual_ocr_paste_canvas_deleted: workspace.manual_ocr_paste_canvas_deleted,
            review_text_paste_dry_run_canvas_deleted: workspace
                .review_text_paste_dry_run_canvas_deleted,
            review_screenshot_extraction_canvas_deleted: workspace
                .review_screenshot_extraction_canvas_deleted,
            scenarios: workspace.scenarios,
            scenarios_seeded: workspace.scenarios_seeded,
            spawn_requires_live_policy: workspace.spawn_requires_live_policy,
            spawn_kill_switch: workspace.spawn_kill_switch,
        }
    }
}
