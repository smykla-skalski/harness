use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{ManagedAgentSnapshot, WsRequest, WsResponse};
use crate::errors::CliError;

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(super) async fn dispatch_managed_agent_response(
    request: &WsRequest,
    state: &DaemonHttpState,
    result: Result<ManagedAgentSnapshot, CliError>,
) -> WsResponse {
    match result {
        Ok(snapshot) => {
            tracing::info!(
                method = %request.method,
                request_id = %request.id,
                kind = %managed_agent_snapshot_kind(&snapshot),
                runtime_id = %snapshot.agent_id(),
                session_id = %snapshot.session_id(),
                "managed agent dispatch returning snapshot"
            );
            if let Err(error) =
                super::super::broadcast_session_snapshot(state, snapshot.session_id()).await
            {
                return super::super::cli_error_response(&request.id, &error);
            }
            super::super::dispatch_query_result(&request.id, Ok::<_, CliError>(snapshot))
        }
        Err(error) => super::super::cli_error_response(&request.id, &error),
    }
}

const fn managed_agent_snapshot_kind(snapshot: &ManagedAgentSnapshot) -> &'static str {
    match snapshot {
        ManagedAgentSnapshot::Terminal(_) => "terminal",
        ManagedAgentSnapshot::Codex(_) => "codex",
        ManagedAgentSnapshot::Acp(_) => "acp",
    }
}
