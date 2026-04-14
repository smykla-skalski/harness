use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;
use crate::observe::types::ObserverState;
use crate::session::types::SessionState;

use super::super::index;
use super::super::protocol::TimelineEntry;
use super::{TimelinePayloadScope, timeline_payload};

pub(super) fn observer_snapshot_entry(
    state: &SessionState,
    context_root: &Path,
    payload_scope: TimelinePayloadScope,
) -> Result<Option<TimelineEntry>, CliError> {
    let Some(observe_id) = state.observe_id.as_deref() else {
        return Ok(None);
    };
    let path = index::observe_snapshot_path(context_root, observe_id);
    if !path.is_file() {
        return Ok(None);
    }

    let observer: ObserverState = read_json_typed(&path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_parse(format!(
            "read observer snapshot {}: {error}",
            path.display()
        )))
    })?;
    if observer.last_scan_time.is_empty() {
        return Ok(None);
    }

    let payload = timeline_payload(&observer, "observer snapshot", payload_scope)?;
    Ok(Some(TimelineEntry {
        entry_id: format!("observe-snapshot-{observe_id}"),
        recorded_at: observer.last_scan_time.clone(),
        kind: "observe_snapshot".into(),
        session_id: state.session_id.clone(),
        agent_id: None,
        task_id: None,
        summary: format!(
            "Observe scan: {} open, {} active workers, {} muted codes",
            observer.open_issues.len(),
            observer.active_workers.len(),
            observer.muted_codes.len()
        ),
        payload,
    }))
}
