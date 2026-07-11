#![allow(
    dead_code,
    reason = "standalone Task Board architecture target reuses a subset of shared helpers"
)]

#[path = "integration/architecture/helpers.rs"]
mod helpers;
#[path = "integration/architecture/task_board_storage.rs"]
mod task_board_storage;
