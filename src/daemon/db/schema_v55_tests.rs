use rusqlite::Connection;

use super::run;

fn client_scopes(conn: &Connection, client_id: &str) -> String {
    conn.query_row(
        "SELECT scopes_json FROM remote_clients WHERE client_id = ?1",
        [client_id],
        |row| row.get(0),
    )
    .expect("stored scopes")
}

fn seeded() -> Connection {
    let conn = Connection::open_in_memory().expect("open memory db");
    conn.execute_batch(
        "CREATE TABLE remote_clients (
            client_id   TEXT PRIMARY KEY,
            role        TEXT NOT NULL,
            scopes_json TEXT NOT NULL
         );
         CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
         INSERT INTO schema_meta (key, value) VALUES ('version', '54');
         INSERT INTO remote_clients (client_id, role, scopes_json) VALUES
            ('admin-default', 'admin', '[\"read\",\"write\",\"admin\"]'),
            ('broker-default', 'pairing_broker', '[\"pair_mint\"]'),
            ('admin-narrowed', 'admin', '[\"read\"]'),
            ('operator', 'operator', '[\"read\",\"write\"]');",
    )
    .expect("seed fixture");
    conn
}

/// An admin or broker that paired before this scope existed still has to reach
/// the routes its role is supposed to reach; scopes are frozen at registration
/// rather than recomputed, so nothing else would give it to them.
#[test]
fn a_role_default_gains_the_new_scope() {
    let conn = seeded();

    run(&conn).expect("run v55");

    assert_eq!(
        client_scopes(&conn, "admin-default"),
        "[\"read\",\"write\",\"admin\",\"pair_manage\"]"
    );
    assert_eq!(
        client_scopes(&conn, "broker-default"),
        "[\"pair_mint\",\"pair_manage\"]"
    );
}

/// A registration that asked for less than its role allows keeps what it asked
/// for. Widening it would hand somebody a power the operator declined to give.
#[test]
fn a_narrowed_registration_is_left_alone() {
    let conn = seeded();

    run(&conn).expect("run v55");

    assert_eq!(client_scopes(&conn, "admin-narrowed"), "[\"read\"]");
    assert_eq!(client_scopes(&conn, "operator"), "[\"read\",\"write\"]");
}

/// The repair chain replays every step, so running twice must not append the
/// scope again.
#[test]
fn running_twice_changes_nothing_more() {
    let conn = seeded();

    run(&conn).expect("first run");
    let once = client_scopes(&conn, "admin-default");
    run(&conn).expect("second run");

    assert_eq!(client_scopes(&conn, "admin-default"), once);
}
