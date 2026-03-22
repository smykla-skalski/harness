pub mod fingerprint;
pub mod handoff;
mod history;
mod paths;
mod render;
mod storage;

#[cfg(test)]
mod tests;

pub use fingerprint::FileFingerprint;
pub use handoff::{CompactHandoff, CreateHandoff, HandoffStatus, RunnerHandoff};
pub use paths::{compact_history_dir, compact_latest_path, compact_project_dir};
pub use render::{render_hydration_context, render_runner_restore_context};
pub use storage::{
    build_compact_handoff, consume_compact_handoff, load_latest_compact_handoff,
    pending_compact_handoff, save_compact_handoff, verify_fingerprints,
};

pub(super) const HANDOFF_VERSION: u32 = 1;
pub(super) const HISTORY_LIMIT: usize = 10;
pub(super) const CHAR_LIMIT: usize = 3500;
pub(super) const SECTION_CHAR_LIMIT: usize = 1600;
pub(super) const SECTION_LINE_LIMIT: usize = 25;

#[must_use]
pub(crate) const fn handoff_version() -> u32 {
    HANDOFF_VERSION
}
