mod connection;
mod dispatch;
mod frames;
mod mutations;
#[cfg(test)]
mod observe_tests;
mod params;
mod queries;
mod relay;
#[cfg(test)]
mod test_support;
#[cfg(test)]
mod tests;

const MAX_INLINE_WS_TEXT_BYTES: usize = 256 * 1024;
const MAX_SEMANTIC_WS_ARRAY_BATCH_BYTES: usize = 128 * 1024;
const MAX_SEMANTIC_WS_ARRAY_BATCH_ITEMS: usize = 64;
const WS_CHUNK_DATA_BYTES: usize = 128 * 1024;

pub use connection::ws_upgrade_handler;
pub use relay::ReplayBuffer;
