use std::path::Path;
use std::time::Duration;

use agent_client_protocol::schema::RequestPermissionResponse;
use tokio::runtime::{Builder, Handle, RuntimeFlavor};
use tokio::sync::oneshot;
use tokio::task::block_in_place;
use tokio::time::timeout;

use crate::agents::acp::permission::PermissionBridgeResult;

use super::error::{
    ClientError, ClientResult, DAEMON_SHUTDOWN, PERMISSION_RUNTIME_UNSUPPORTED, PERMISSION_TIMEOUT,
};

pub(super) fn ensure_permission_bridge_wait_runtime_supported() -> ClientResult<()> {
    let Ok(current) = Handle::try_current() else {
        return Ok(());
    };
    if matches!(current.runtime_flavor(), RuntimeFlavor::CurrentThread) {
        return Err(ClientError::new(
            PERMISSION_RUNTIME_UNSUPPORTED,
            "daemon bridge permission waits must run on a blocking thread outside tokio current-thread runtimes",
        ));
    }
    Ok(())
}

// Raw synchronous waits are supported outside Tokio and on Tokio multi-thread
// runtimes. Current-thread runtimes must move the whole client call to
// spawn_blocking so the bridge worker is never starved by the waiter.
pub(super) fn wait_permission_bridge_response(
    deadline: Duration,
    response_rx: oneshot::Receiver<PermissionBridgeResult>,
) -> ClientResult<RequestPermissionResponse> {
    let future = async move {
        match timeout(deadline, response_rx).await {
            Ok(Ok(Ok(response))) => Ok(response),
            Ok(Ok(Err(error))) => Err(ClientError::new(error.code, error.message)),
            Ok(Err(_)) => Err(ClientError::new(
                DAEMON_SHUTDOWN,
                "permission bridge disconnected",
            )),
            Err(_) => Err(ClientError::new(
                PERMISSION_TIMEOUT,
                "permission response timed out",
            )),
        }
    };

    match Handle::try_current() {
        Ok(current) => match current.runtime_flavor() {
            RuntimeFlavor::MultiThread => block_in_place(|| current.block_on(future)),
            RuntimeFlavor::CurrentThread => Err(ClientError::new(
                PERMISSION_RUNTIME_UNSUPPORTED,
                "daemon bridge permission waits must run on a blocking thread outside tokio current-thread runtimes",
            )),
            _ => current.block_on(future),
        },
        Err(_) => Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| {
                ClientError::new(
                    PERMISSION_TIMEOUT,
                    format!("build permission wait runtime: {error}"),
                )
            })?
            .block_on(future),
    }
}

pub(super) fn is_path_within(base: &Path, path: &Path) -> bool {
    let Ok(canonical_base) = base.canonicalize() else {
        return false;
    };
    let Ok(canonical_path) = path.canonicalize() else {
        if let Some(parent) = path.parent()
            && let Ok(canonical_parent) = parent.canonicalize()
        {
            return canonical_parent.starts_with(&canonical_base);
        }
        return false;
    };
    canonical_path.starts_with(&canonical_base)
}
