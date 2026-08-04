-- The outline half of a project's mark. Colour runs out at the size of the
-- palette; past that two projects must share one, and the shape is what still
-- tells them apart.
--
-- Nullable on purpose. A board small enough for colour alone stores nothing
-- here and every project wears the default, so the column only fills once it
-- has something to say. Like the colour CHECK, this constrains shape only and
-- never names the set; `TaskBoardProjectShape` decides what is a shape.
ALTER TABLE task_board_projects ADD COLUMN shape TEXT
    CONSTRAINT task_board_projects_shape_shape
    CHECK (
        shape IS NULL
        OR (
            length(shape) > 0
            AND length(CAST(shape AS BLOB)) <= 32
            AND shape NOT GLOB '*[^a-z_]*'
        )
    );
