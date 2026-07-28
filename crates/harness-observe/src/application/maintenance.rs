// Only `storage` (the observer-state event log/snapshot I/O) is reachable
// from `harness-daemon`; every other submodule here backs a CLI dispatch
// action (`observe scan --action ...`) that only the CLI's own transport
// layer ever calls, so they stay behind the `cli` feature alongside it.
#[cfg(feature = "cli")]
#[path = "maintenance/catalog.rs"]
mod catalog;
#[cfg(feature = "cli")]
#[path = "maintenance/inspection.rs"]
mod inspection;
#[cfg(feature = "cli")]
#[path = "maintenance/mutations.rs"]
mod mutations;
#[cfg(feature = "cli")]
#[path = "maintenance/render.rs"]
mod render;
#[cfg(feature = "cli")]
#[path = "maintenance/scan.rs"]
mod scan;
#[cfg(feature = "cli")]
#[path = "maintenance/status.rs"]
mod status;
#[path = "maintenance/storage.rs"]
mod storage;

#[cfg(feature = "cli")]
pub(super) use catalog::{execute_list_categories, execute_list_focus_presets};
#[cfg(feature = "cli")]
pub(super) use inspection::{execute_resolve_start, execute_verify};
#[cfg(feature = "cli")]
pub(super) use mutations::{execute_mute, execute_unmute};
#[cfg(feature = "cli")]
pub(super) use render::{render_json, render_pretty_json};
#[cfg(feature = "cli")]
pub(super) use scan::{execute_cycle, execute_resume};
#[cfg(feature = "cli")]
pub(super) use status::execute_status;
pub use storage::{is_observer_conflict, load_observer_state, save_observer_state};
