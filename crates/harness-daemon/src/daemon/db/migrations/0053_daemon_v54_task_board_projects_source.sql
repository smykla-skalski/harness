-- Rebuild task_board_projects so `source` no longer accepts 'todoist'.
--
-- Both callers must run this with foreign_keys suspended. SQLite rewrites
-- every REFERENCES clause that points at a renamed table, so under enforcement
-- the rename below repoints task_board_items.source_project_id at the temp
-- table this file then drops. The pragma is a no-op inside a transaction, so
-- it cannot live here: schema_v54.rs suspends it around its own transaction,
-- and the sqlx path suspends it around the whole migrator run.
--
-- `color` and `shape` arrived as v52 and v53 ALTERs and have to be spelled out
-- again here: a rebuild replaces the table, so any column missing from this
-- definition is dropped along with every value in it.
ALTER TABLE task_board_projects RENAME TO task_board_projects_pre_v54;

CREATE TABLE task_board_projects (
    -- The hex clause matters as much as the length one: `is_project_id`
    -- treats a non-hex value as unassigned, so a row the column accepted but
    -- that predicate rejects would persist and read as having no project.
    project_id    TEXT PRIMARY KEY
                      CHECK (
                          substr(project_id, 1, 8) = 'project-'
                          AND length(project_id) = 40
                          AND substr(project_id, 9) NOT GLOB '*[^0-9a-f]*'
                      ),
    source        TEXT NOT NULL CHECK (source IN ('github', 'manual')),
    slug          TEXT NOT NULL
                      CHECK (
                          length(trim(slug)) > 0
                          AND length(CAST(slug AS BLOB)) <= 256
                      ),
    display_name  TEXT
                      CHECK (
                          display_name IS NULL
                          OR (
                              length(trim(display_name)) > 0
                              AND length(CAST(display_name AS BLOB)) <= 256
                          )
                      ),
    created_at    TEXT NOT NULL CHECK (created_at GLOB '????-??-??T??:??:??Z'),
    updated_at    TEXT NOT NULL CHECK (updated_at GLOB '????-??-??T??:??:??Z'),
    color         TEXT
                      CONSTRAINT task_board_projects_color_shape
                      CHECK (
                          color IS NULL
                          OR (
                              length(color) > 0
                              AND length(CAST(color AS BLOB)) <= 32
                              AND color NOT GLOB '*[^a-z_]*'
                          )
                      ),
    shape         TEXT
                      CONSTRAINT task_board_projects_shape_shape
                      CHECK (
                          shape IS NULL
                          OR (
                              length(shape) > 0
                              AND length(CAST(shape AS BLOB)) <= 32
                              AND shape NOT GLOB '*[^a-z_]*'
                          )
                      ),
    UNIQUE(source, slug)
) WITHOUT ROWID;

INSERT INTO task_board_projects (
    project_id, source, slug, display_name, created_at, updated_at, color, shape
)
SELECT project_id, source, slug, display_name, created_at, updated_at, color, shape
FROM task_board_projects_pre_v54;

DROP TABLE task_board_projects_pre_v54;

CREATE INDEX IF NOT EXISTS task_board_projects_source_slug
    ON task_board_projects(source, slug);

-- Only the last v54 file stamps the version. Stamping in 0052 would claim v54
-- while the source check still names todoist, and the async bootstrap trusts
-- this value rather than re-inspecting the table shape.
UPDATE schema_meta SET value = '54' WHERE key = 'version';
