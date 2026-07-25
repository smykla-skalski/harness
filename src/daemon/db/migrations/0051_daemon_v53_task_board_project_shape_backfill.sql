-- Replayable, like the v52 colour backfill it follows, and for the same reason:
-- if the ALTER lands and the process dies, the next boot skips the ALTER and
-- this still fills every row. `WHERE shape IS NULL` is what makes replaying it
-- free, and it also pins a shape once assigned so a later registration cannot
-- move an organization's outline out from under it.
--
-- The shapes are spelled out once, in allocation order, and the modulus is read
-- back off that list rather than written as a number.
-- `migration_backfill_matches_the_shapes` holds the list to
-- `TaskBoardProjectShape::SHAPES`, and `migration_groups_by_organization` holds
-- the owner expression below to `organization_of`.
WITH shapes(slot, name) AS (
    VALUES
        (0, 'circle'),
        (1, 'square'),
        (2, 'triangle'),
        (3, 'diamond'),
        (4, 'hexagon'),
        (5, 'pentagon')
),
palette(name) AS (
    VALUES
        ('blue'), ('green'), ('purple'), ('amber'), ('teal'), ('pink'),
        ('mint'), ('sky'), ('warm'), ('olive'), ('graphite'), ('red'),
        ('blue_deep'), ('green_deep'), ('purple_deep'), ('amber_deep'),
        ('teal_deep'), ('pink_deep'), ('mint_deep'), ('sky_deep'),
        ('warm_deep'), ('olive_deep'), ('graphite_deep'), ('red_deep')
),
organizations AS (
    SELECT owner,
           ROW_NUMBER() OVER (ORDER BY first_seen, owner) - 1 AS position
    FROM (
        SELECT CASE
                   WHEN instr(slug, '/') > 0 THEN substr(slug, 1, instr(slug, '/') - 1)
                   ELSE slug
               END AS owner,
               MIN(created_at) AS first_seen
        FROM task_board_projects
        GROUP BY 1
    )
)
UPDATE task_board_projects
SET shape = (
    SELECT shapes.name
    FROM organizations
    JOIN shapes
      ON shapes.slot = organizations.position % (SELECT COUNT(*) FROM shapes)
    WHERE organizations.owner = CASE
        WHEN instr(task_board_projects.slug, '/') > 0
            THEN substr(task_board_projects.slug, 1, instr(task_board_projects.slug, '/') - 1)
        ELSE task_board_projects.slug
    END
)
WHERE shape IS NULL
  -- A board colour alone still covers wears no outline at all. Crossing the
  -- palette is what turns the second channel on, for every project at once.
  AND (SELECT COUNT(*) FROM task_board_projects) > (SELECT COUNT(*) FROM palette);

UPDATE schema_meta SET value = '53' WHERE key = 'version';
