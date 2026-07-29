use clap::Parser;

use crate::daemon::db::DaemonDb;
use crate::daemon::remote_pairing::RemotePairingCode;

use super::super::{DaemonRemoteCommand, DaemonRemotePairCommand};

#[derive(Debug, Parser)]
struct DaemonRemoteCommandTestHarness {
    #[command(subcommand)]
    command: DaemonRemoteCommand,
}

#[test]
fn daemon_remote_pair_create_fails_closed_without_remote_tls_identity() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let parsed = DaemonRemoteCommandTestHarness::try_parse_from(["test", "pair", "create"])
        .unwrap()
        .command;
    let DaemonRemoteCommand::Pair {
        command: DaemonRemotePairCommand::Create(args),
    } = parsed
    else {
        panic!("expected pair create");
    };
    let code = RemotePairingCode::from_value_for_tests("manual-code-value");

    let error = args
        .create_pairing_with(
            &db,
            "pairing-test",
            "audit-pairing-test",
            &code,
            "2026-06-21T13:40:00Z",
        )
        .expect_err("pairing must require persisted TLS identity");

    assert!(error.to_string().contains("persisted remote TLS identity"));
    let stored_count: i64 = db
        .connection()
        .query_row("SELECT COUNT(*) FROM remote_pairing_codes", [], |row| {
            row.get(0)
        })
        .expect("stored pairing count");
    assert_eq!(stored_count, 0);
}
