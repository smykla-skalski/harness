use crate::daemon::state;

use super::core::ResolvedBridgeConfig;

pub(super) fn record_bridge_started(config: &ResolvedBridgeConfig) {
    state::append_event_best_effort(
        "info",
        &format!(
            "host bridge listening on {} with capabilities {}",
            config.socket_path.display(),
            config
                .capabilities
                .iter()
                .map(|capability| capability.name())
                .collect::<Vec<_>>()
                .join(",")
        ),
    );
}

pub(super) fn record_bridge_stopped() {
    state::append_event_best_effort("info", "host bridge stopped");
}
