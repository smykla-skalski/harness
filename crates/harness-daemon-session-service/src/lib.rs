//! Daemon session lifecycle services.
//!
//! Signal delivery is the first extracted slice. Persistence is reached
//! through caller-owned ports so this crate never depends on the daemon
//! crate that wires it into HTTP, WebSocket, and managed-agent runtimes.

mod async_ops;
mod async_send;
mod persistence;
mod ports;
mod sync;
mod timeout;
mod tui_identity;

pub use async_ops::{cancel_signal_async, record_signal_ack_direct_async};
pub use async_send::send_signal_async;
pub use persistence::{
    acknowledged_signal_record, build_signal_ack, pending_signal_record, record_signal_ack,
};
pub use ports::{AsyncSignalStorage, SignalStorage, SignalWake};
pub use sync::{attempt_active_signal_delivery, build_active_signal_prompt, send_signal};
pub use sync::{cancel_signal, managed_tui_id_for_registration};
