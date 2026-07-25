-- Runs unconditionally, unlike the ALTER it follows. Splitting them splits the
-- crash window: if the column lands and the process dies before this file, the
-- next boot skips the ALTER and still fills every row, instead of leaving the
-- projects the registry already held without a color for good. `WHERE color IS
-- NULL` is what makes replaying it free.
--
-- The palette is spelled out once, in allocation order, and the modulus is read
-- back off that list rather than written as a number, so a color added here
-- cannot fall out of step with the count. `migration_backfill_matches_the_palette`
-- holds the list itself to `TaskBoardProjectColor::PALETTE`.
WITH palette(slot, name) AS (
    VALUES
        (0, 'blue'),
        (1, 'green'),
        (2, 'purple'),
        (3, 'amber'),
        (4, 'teal'),
        (5, 'pink'),
        (6, 'red'),
        (7, 'mint'),
        (8, 'sky'),
        (9, 'warm'),
        (10, 'graphite')
),
unassigned AS (
    SELECT project_id,
           ROW_NUMBER() OVER (ORDER BY created_at, project_id) - 1 AS position
    FROM task_board_projects
    WHERE color IS NULL
)
UPDATE task_board_projects
SET color = (
    SELECT palette.name
    FROM unassigned
    JOIN palette
      ON palette.slot = unassigned.position % (SELECT COUNT(*) FROM palette)
    WHERE unassigned.project_id = task_board_projects.project_id
)
WHERE color IS NULL;

UPDATE schema_meta SET value = '52' WHERE key = 'version';
