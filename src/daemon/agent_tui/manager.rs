use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use tokio::runtime::Handle;
use tokio::sync::broadcast;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::protocol::StreamEvent;

use super::process::AgentTuiProcess;

#[derive(Clone)]
pub(crate) struct ActiveAgentTui {
    pub(crate) process: Option<Arc<AgentTuiProcess>>,
    pub(crate) stop_flag: Arc<AtomicBool>,
}

impl ActiveAgentTui {
    pub(crate) fn new(process: Option<Arc<AgentTuiProcess>>) -> Self {
        Self {
            process,
            stop_flag: Arc::new(AtomicBool::new(false)),
        }
    }

    pub(crate) fn stop(&self) {
        self.stop_flag.store(true, Ordering::Relaxed);
    }
}

/// Daemon-owned manager for interactive agent runtime PTYs.
#[derive(Clone)]
pub struct AgentTuiManagerHandle {
    pub(crate) state: Arc<AgentTuiManagerState>,
}

pub(crate) struct AgentTuiManagerState {
    pub(crate) sender: broadcast::Sender<StreamEvent>,
    pub(crate) db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    pub(crate) async_db: Arc<OnceLock<Arc<AsyncDaemonDb>>>,
    pub(crate) runtime: Option<Handle>,
    pub(crate) active: Mutex<BTreeMap<String, ActiveAgentTui>>,
    pub(crate) sandboxed: bool,
}

impl AgentTuiManagerHandle {
    /// Create a manager bound to the daemon DB and event stream.
    #[must_use]
    pub fn new(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
        sandboxed: bool,
    ) -> Self {
        Self::new_with_async_db(sender, db, Arc::new(OnceLock::new()), sandboxed)
    }

    #[must_use]
    pub(crate) fn new_with_async_db(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
        async_db: Arc<OnceLock<Arc<AsyncDaemonDb>>>,
        sandboxed: bool,
    ) -> Self {
        Self {
            state: Arc::new(AgentTuiManagerState {
                sender,
                db,
                async_db,
                runtime: Handle::try_current().ok(),
                active: Mutex::new(BTreeMap::new()),
                sandboxed,
            }),
        }
    }
}
