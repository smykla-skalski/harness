-- Attribution gets its own column rather than reusing `project_id`. That one
-- carries the provider's own project value and is compared against the remote
-- task on every sync, so an opaque board identifier there would make every
-- provider-linked item read as permanently diverged.
ALTER TABLE task_board_items ADD COLUMN source_project_id TEXT
    REFERENCES task_board_projects(project_id)
    CONSTRAINT task_board_items_source_project_id_shape
    CHECK (
        source_project_id IS NULL
        OR (
            substr(source_project_id, 1, 8) = 'project-'
            AND length(source_project_id) = 40
            AND substr(source_project_id, 9) NOT GLOB '*[^0-9a-f]*'
        )
    );

-- Where each existing item came from, resolved once so the INSERT and the
-- UPDATE below can never disagree about which source a slug belongs to.
-- `project_id` is read first because an item that names its own project means
-- it; GitHub imports named theirs only in `execution_repository`.
CREATE TABLE task_board_projects_backfill AS
WITH candidate AS (
    SELECT item_id,
           imported_from_provider,
           CASE
               WHEN project_id IS NOT NULL AND length(trim(project_id)) > 0
                   THEN trim(project_id)
               WHEN execution_repository IS NOT NULL AND length(trim(execution_repository)) > 0
                   THEN trim(execution_repository)
           END AS raw
    FROM task_board_items
),
split AS (
    SELECT item_id,
           imported_from_provider,
           raw,
           CASE
               WHEN instr(raw, '/') > 0
                   THEN trim(substr(raw, 1, instr(raw, '/') - 1))
           END AS owner,
           CASE
               WHEN instr(raw, '/') > 0
                   THEN trim(substr(raw, instr(raw, '/') + 1))
           END AS repository
    FROM candidate
    WHERE raw IS NOT NULL
),
classified AS (
    -- Mirrors normalize_repository_slug: split on the first separator, trim
    -- each half, and require both to be non-empty with no second separator.
    -- The runtime path reruns that function on every write, so any rule the
    -- two spellings disagree on splits one repository across two projects.
    SELECT item_id,
           imported_from_provider,
           raw,
           owner,
           repository,
           owner IS NOT NULL
               AND length(owner) > 0
               AND length(repository) > 0
               AND instr(repository, '/') = 0 AS is_repository
    FROM split
)
SELECT item_id,
       CASE
           WHEN is_repository THEN 'github'
           WHEN imported_from_provider = 'todoist' THEN 'todoist'
           ELSE 'manual'
       END AS source,
       CASE
           WHEN is_repository THEN lower(owner || '/' || repository)
           ELSE raw
       END AS slug
FROM classified;

INSERT OR IGNORE INTO task_board_projects (
    project_id, source, slug, display_name, created_at, updated_at
)
SELECT 'project-' || lower(hex(randomblob(16))),
       source,
       slug,
       NULL,
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
       strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
FROM (SELECT DISTINCT source, slug FROM task_board_projects_backfill);

UPDATE task_board_items
SET source_project_id = (
    SELECT projects.project_id
    FROM task_board_projects_backfill AS backfill
    JOIN task_board_projects AS projects
      ON projects.source = backfill.source AND projects.slug = backfill.slug
    WHERE backfill.item_id = task_board_items.item_id
)
WHERE item_id IN (SELECT item_id FROM task_board_projects_backfill);

DROP TABLE task_board_projects_backfill;

UPDATE schema_meta SET value = '51' WHERE key = 'version';
