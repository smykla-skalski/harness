mod broadcast;
mod config;
mod connection;
mod dispatch;
mod frames;
mod mutations;
#[cfg(test)]
mod observe_tests;
mod params;
mod parity;
mod queries;
mod relay;
mod reviews;
#[cfg(test)]
mod session_start_tests;
#[cfg(test)]
mod signal_tests;
mod task_board;
#[cfg(test)]
mod telemetry_tests;
#[cfg(test)]
mod test_support;
#[cfg(test)]
mod tests;

const MAX_INLINE_WS_TEXT_BYTES: usize = 256 * 1024;
const MAX_SEMANTIC_WS_ARRAY_BATCH_BYTES: usize = 128 * 1024;
const MAX_SEMANTIC_WS_ARRAY_BATCH_ITEMS: usize = 64;
const WS_CHUNK_DATA_BYTES: usize = 128 * 1024;

pub(crate) use broadcast::run_broadcast_fanout;
pub use broadcast::{PreparedBroadcast, ReplayBuffer};
pub(crate) use config::build_config_payload;
pub use connection::ws_upgrade_handler;
