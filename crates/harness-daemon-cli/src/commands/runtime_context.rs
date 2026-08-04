use harness_daemon::daemon::cli_support::adopt_daemon_root_for_transport_command;
use harness_daemon::daemon::state;

use super::DaemonCommand;

pub struct DaemonRuntimeContext {
    _ownership: Option<state::ScopedOwnershipOverride>,
    _root: Option<state::ScopedDaemonRootOverride>,
}

impl DaemonCommand {
    #[must_use]
    pub fn prepare_runtime_context(&self) -> DaemonRuntimeContext {
        let (ownership, root) = match self {
            Self::Dev(args) => {
                let plan = args.execution_plan();
                let ownership =
                    state::ScopedOwnershipOverride::set(Some(state::DaemonOwnership::External));
                let root = state::ScopedDaemonRootOverride::set(Some(plan.daemon_root));
                (Some(ownership), Some(root))
            }
            Self::Status => prepare_transport("daemon-status"),
            Self::Identity(_) => prepare_transport("daemon-identity"),
            Self::Stop(_) => prepare_transport("daemon-stop"),
            Self::Restart(_) => prepare_transport("daemon-restart"),
            Self::Doctor => prepare_transport("daemon-doctor"),
            Self::Snapshot(_) => prepare_transport("daemon-snapshot"),
            _ => (None, None),
        };
        DaemonRuntimeContext {
            _ownership: ownership,
            _root: root,
        }
    }
}

fn prepare_transport(
    command: &'static str,
) -> (
    Option<state::ScopedOwnershipOverride>,
    Option<state::ScopedDaemonRootOverride>,
) {
    adopt_daemon_root_for_transport_command(command);
    (None, None)
}
