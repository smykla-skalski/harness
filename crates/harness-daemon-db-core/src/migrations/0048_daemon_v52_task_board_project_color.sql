-- The color a card wears to name the project its work came from. Added rather
-- than folded into the table definition so an existing registry gains it
-- without a rebuild.
--
-- The CHECK deliberately does not name the palette. Which colors exist is a
-- product decision that can grow, and pinning the set here would turn adding
-- one into a schema migration. This only keeps a shapeless value out;
-- `TaskBoardProjectColor` decides what is actually a color, and a stored name
-- it no longer knows falls back rather than failing the read.
ALTER TABLE task_board_projects ADD COLUMN color TEXT
    CONSTRAINT task_board_projects_color_shape
    CHECK (
        color IS NULL
        OR (
            length(color) > 0
            AND length(CAST(color AS BLOB)) <= 32
            AND color NOT GLOB '*[^a-z_]*'
        )
    );
