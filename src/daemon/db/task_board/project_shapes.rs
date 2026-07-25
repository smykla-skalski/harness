use std::collections::BTreeMap;

use sqlx::{Sqlite, Transaction, query};

use crate::daemon::db::{CliError, db_error};
use crate::task_board::project_shape::{
    self, TaskBoardProjectShape, colors_alone_suffice, organization_of,
};

/// Give every project an outline once colour alone can no longer keep the board
/// apart, and leave it alone before that.
///
/// Runs on registration rather than on read, because it writes. Registration is
/// rare and already inside a transaction, so the scan costs nothing that shows.
///
/// # Errors
/// Returns [`CliError`] when the registry cannot be read or written.
pub(crate) async fn assign_shapes_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<(), CliError> {
    let rows = sqlx::query_as::<_, (String, String, Option<String>)>(
        "SELECT project_id, slug, shape FROM task_board_projects ORDER BY created_at, project_id",
    )
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read task board project shapes: {error}")))?;

    if colors_alone_suffice(rows.len()) {
        return Ok(());
    }

    // An organization that already has an outline keeps it. Reshuffling on
    // every registration would mean a board that looks different after each new
    // project, which is the opposite of what a mark is for.
    let mut by_organization: BTreeMap<&str, TaskBoardProjectShape> = BTreeMap::new();
    for (_, slug, shape) in &rows {
        if let Some(shape) = shape.as_deref().and_then(TaskBoardProjectShape::parse) {
            by_organization.entry(organization_of(slug)).or_insert(shape);
        }
    }

    let mut pending: Vec<(&str, TaskBoardProjectShape)> = Vec::new();
    for (project_id, slug, shape) in &rows {
        if shape.is_some() {
            continue;
        }
        let organization = organization_of(slug);
        let assigned = if let Some(assigned) = by_organization.get(organization) {
            *assigned
        } else {
            let taken: Vec<TaskBoardProjectShape> = by_organization.values().copied().collect();
            let allocated = project_shape::allocate(&taken);
            by_organization.insert(organization, allocated);
            allocated
        };
        pending.push((project_id, assigned));
    }

    for (project_id, shape) in pending {
        query("UPDATE task_board_projects SET shape = ?2 WHERE project_id = ?1 AND shape IS NULL")
            .bind(project_id)
            .bind(shape.as_str())
            .execute(transaction.as_mut())
            .await
            .map_err(|error| {
                db_error(format!("assign task board project shape '{project_id}': {error}"))
            })?;
    }
    Ok(())
}
