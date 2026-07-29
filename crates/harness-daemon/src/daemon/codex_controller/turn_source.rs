use serde_json::json;
use uuid::Uuid;

use crate::agents::turn::AgentTurnPullRequest;
use crate::daemon::protocol::{CodexRunRequest, CodexRunSnapshot};
use harness_kernel::errors::CliError;

use super::CodexControllerHandle;
use super::handle::record_snapshot_event;

impl CodexControllerHandle {
    pub(super) fn start_agent_turn(
        &self,
        session_id: &str,
        request: &CodexRunRequest,
        pull_request: Option<&AgentTurnPullRequest>,
    ) -> Result<CodexRunSnapshot, CliError> {
        let session_id = session_id.to_string();
        let label = session_id.clone();
        self.finish_starting_run(
            format!("codex-{}", Uuid::new_v4()),
            &label,
            move |controller, run_id| {
                controller.prepare_durable_run(&session_id, request, pull_request, run_id)
            },
        )
    }
}

pub(super) fn record_bound_pull_request(
    snapshot: &mut CodexRunSnapshot,
    pull_request: Option<&AgentTurnPullRequest>,
) {
    let Some(pull_request) = pull_request else {
        return;
    };
    record_snapshot_event(
        snapshot,
        "source/bound",
        format!(
            "Bound {}#{} at {}",
            pull_request.repository, pull_request.number, pull_request.head_revision
        ),
        &json!({
            "repository": pull_request.repository,
            "pullRequestNumber": pull_request.number,
            "headRevision": pull_request.head_revision,
            "readOnly": true
        }),
    );
}

pub(super) fn source_revision(snapshot: &CodexRunSnapshot) -> Option<String> {
    snapshot.events.iter().find_map(|event| {
        (event.kind == "source/bound")
            .then(|| {
                event
                    .payload
                    .get("headRevision")?
                    .as_str()
                    .map(ToOwned::to_owned)
            })
            .flatten()
    })
}
