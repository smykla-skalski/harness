//! Lane-placement's own interface onto [`AsyncDaemonDb`], scoped to moving an
//! item to a manual position, resetting it to derived ordering, and placing
//! automation-produced items.
//!
//! `task_board` doesn't own `AsyncDaemonDb` -- it's a sibling module's type --
//! so an inherent `impl AsyncDaemonDb` block for lane-placement queries can
//! never move into a crate `task_board` doesn't share with `db`. A trait
//! `task_board` itself declares has no such problem: Rust's orphan rule only
//! requires one of the trait or the implementing type to be local, and the
//! trait is. That is what lets this one area's queries move into their own
//! crate later without dragging every other area's inherent impls along for
//! the ride.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside `db/task_board`
//! has to change to keep calling them by the same name.

use super::lane_order_api::{
    TaskBoardLaneMutationResult, TaskBoardLanePositionInput, TaskBoardLaneResetInput,
};
use crate::daemon::db::{AsyncDaemonDb, CliError};

pub(crate) trait LanePlacementQueries: Send + Sync {
    /// Apply a manual absolute slot change under one item-list sequence CAS.
    ///
    /// # Errors
    /// Returns [`CliError`] when the item is unknown, the sequence or
    /// revision no longer matches, or the requested placement is invalid.
    async fn set_task_board_lane_position(
        &self,
        input: TaskBoardLanePositionInput,
    ) -> Result<TaskBoardLaneMutationResult, CliError>;

    /// Reset an item to derived default ordering under one item-list sequence
    /// CAS. An active override reasserts through it -- reset means "return to
    /// override-derived ordering", not "fall to unranked default" -- unless a
    /// dispatch reservation is also active, in which case the reset is
    /// rejected atomically rather than clearing the anchor and leaving the
    /// reapply suppressed.
    ///
    /// # Errors
    /// Returns [`CliError`] when the item is unknown, has no explicit
    /// position to reset, the sequence or revision no longer matches, or an
    /// active dispatch reservation blocks the reset.
    async fn reset_task_board_lane_position(
        &self,
        input: TaskBoardLaneResetInput,
    ) -> Result<TaskBoardLaneMutationResult, CliError>;

    /// Later automation can use this internal seam without replacing manual
    /// anchors or an active override's lane/provenance -- the latter is the
    /// override choke point's job to reassert, not arbitrary automation's.
    ///
    /// # Errors
    /// Returns [`CliError`] when the item is unknown or the placement fails.
    async fn place_task_board_item_automatically(
        &self,
        item_id: &str,
        lane_position: u32,
        producer: String,
    ) -> Result<Option<TaskBoardLaneMutationResult>, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the free function that actually owns the
/// area's query logic, kept in `lane_order_api.rs` so this file stays a pure
/// interface plus wiring, not a dumping ground.
impl LanePlacementQueries for AsyncDaemonDb {
    async fn set_task_board_lane_position(
        &self,
        input: TaskBoardLanePositionInput,
    ) -> Result<TaskBoardLaneMutationResult, CliError> {
        super::lane_order_api::set_task_board_lane_position(self, input).await
    }

    async fn reset_task_board_lane_position(
        &self,
        input: TaskBoardLaneResetInput,
    ) -> Result<TaskBoardLaneMutationResult, CliError> {
        super::lane_order_api::reset_task_board_lane_position(self, input).await
    }

    async fn place_task_board_item_automatically(
        &self,
        item_id: &str,
        lane_position: u32,
        producer: String,
    ) -> Result<Option<TaskBoardLaneMutationResult>, CliError> {
        super::lane_order_api::place_task_board_item_automatically(
            self,
            item_id,
            lane_position,
            producer,
        )
        .await
    }
}
