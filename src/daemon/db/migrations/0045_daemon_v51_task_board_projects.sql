-- A project is the source a board item's work came from. `project_id` is
-- assigned once and never rewritten, so renaming a project is an UPDATE of
-- `slug` that leaves every attached item alone. `source` scopes `slug`
-- because two providers may hand out the same slug for unrelated projects.
CREATE TABLE IF NOT EXISTS task_board_projects (
    project_id    TEXT PRIMARY KEY
                      CHECK (
                          substr(project_id, 1, 8) = 'project-'
                          AND length(project_id) = 40
                      ),
    source        TEXT NOT NULL CHECK (source IN ('github', 'todoist', 'manual')),
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
    UNIQUE(source, slug)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS task_board_projects_source_slug
    ON task_board_projects(source, slug);
