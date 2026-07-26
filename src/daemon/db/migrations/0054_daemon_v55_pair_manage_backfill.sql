-- Give `pair_manage` to the clients whose role now carries it.
--
-- Scopes are frozen into `scopes_json` when a client registers, not recomputed
-- from its role per request, so an admin or broker that paired before this
-- scope existed would be refused the routes its role is supposed to reach.
--
-- Only a client holding exactly the old default for its role is touched. A
-- registration that deliberately asked for less keeps what it asked for:
-- widening it here would hand somebody a power the operator declined to give.
UPDATE remote_clients
SET scopes_json = json_insert(scopes_json, '$[#]', 'pair_manage')
WHERE role = 'admin'
  AND (SELECT COUNT(*) FROM json_each(remote_clients.scopes_json)) = 3
  AND EXISTS (SELECT 1 FROM json_each(remote_clients.scopes_json) WHERE value = 'read')
  AND EXISTS (SELECT 1 FROM json_each(remote_clients.scopes_json) WHERE value = 'write')
  AND EXISTS (SELECT 1 FROM json_each(remote_clients.scopes_json) WHERE value = 'admin');

UPDATE remote_clients
SET scopes_json = json_insert(scopes_json, '$[#]', 'pair_manage')
WHERE role = 'pairing_broker'
  AND (SELECT COUNT(*) FROM json_each(remote_clients.scopes_json)) = 1
  AND EXISTS (SELECT 1 FROM json_each(remote_clients.scopes_json) WHERE value = 'pair_mint');

-- Both paths take the version from here: the async bootstrap trusts this value
-- rather than re-deriving it, and the sync step is this file and nothing else.
UPDATE schema_meta SET value = '55' WHERE key = 'version';
