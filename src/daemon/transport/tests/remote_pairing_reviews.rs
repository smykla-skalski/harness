use clap::Parser;

use crate::daemon::db::DaemonDb;
use crate::daemon::remote_pairing::RemotePairingCode;

use super::super::{DaemonRemoteCommand, DaemonRemotePairCommand};
use super::remote_cli::seed_remote_tls_identity;

#[derive(Debug, Parser)]
struct DaemonRemoteCommandTestHarness {
    #[command(subcommand)]
    command: DaemonRemoteCommand,
}

#[test]
fn daemon_remote_pair_create_builds_normalized_reviews_query() {
    let parsed = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "pair",
        "create",
        "--reviews-authors",
        " renovate[bot] ,renovate[bot]",
        "--reviews-organizations",
        " smykla-skalski ",
        "--reviews-repositories",
        "smykla-skalski/harness,smykla-skalski/harness",
        "--reviews-exclude-repositories",
        " smykla-skalski/archive ",
        "--reviews-cache-max-age-seconds",
        "45",
    ])
    .expect("parse pair create reviews query")
    .command;
    let DaemonRemoteCommand::Pair {
        command: DaemonRemotePairCommand::Create(args),
    } = parsed
    else {
        panic!("expected pair create");
    };

    let query = args
        .reviews_query()
        .expect("valid reviews query")
        .expect("configured reviews query");

    assert_eq!(query.authors, vec!["renovate[bot]"]);
    assert_eq!(query.organizations, vec!["smykla-skalski"]);
    assert_eq!(query.repositories, vec!["smykla-skalski/harness"]);
    assert_eq!(query.exclude_repositories, vec!["smykla-skalski/archive"]);
    assert_eq!(query.cache_max_age_seconds, 45);
}

#[test]
fn daemon_remote_pair_create_returns_persisted_reviews_query() {
    let parsed = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "pair",
        "create",
        "--reviews-repositories",
        " smykla-skalski/harness ",
        "--reviews-cache-max-age-seconds",
        "45",
    ])
    .expect("parse pair create reviews query")
    .command;
    let DaemonRemoteCommand::Pair {
        command: DaemonRemotePairCommand::Create(args),
    } = parsed
    else {
        panic!("expected pair create");
    };
    let db = DaemonDb::open_in_memory().expect("open db");
    seed_remote_tls_identity(&db);
    let code = RemotePairingCode::from_value_for_tests("reviews-pairing-secret");

    let response = args
        .create_pairing_with(
            &db,
            "pairing-reviews-response",
            "audit-pairing-reviews-response",
            &code,
            "2026-07-12T18:00:00Z",
        )
        .expect("create pairing");
    let query = response.reviews_query.expect("Reviews query response");

    assert_eq!(query.repositories, vec!["smykla-skalski/harness"]);
    assert_eq!(query.cache_max_age_seconds, 45);
}

#[test]
fn daemon_remote_pair_create_rejects_unscoped_reviews_authors() {
    let parsed = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "pair",
        "create",
        "--reviews-authors",
        "renovate[bot]",
    ])
    .expect("parse pair create")
    .command;
    let DaemonRemoteCommand::Pair {
        command: DaemonRemotePairCommand::Create(args),
    } = parsed
    else {
        panic!("expected pair create");
    };

    let error = args
        .reviews_query()
        .expect_err("unscoped authors must fail");

    assert!(error.to_string().contains("organization or repository"));
}

#[test]
fn daemon_remote_pair_create_rejects_unscoped_reviews_cache_setting() {
    let parsed = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "pair",
        "create",
        "--reviews-cache-max-age-seconds",
        "45",
    ])
    .expect("parse pair create")
    .command;
    let DaemonRemoteCommand::Pair {
        command: DaemonRemotePairCommand::Create(args),
    } = parsed
    else {
        panic!("expected pair create");
    };

    let error = args
        .reviews_query()
        .expect_err("unscoped cache setting must fail");

    assert!(error.to_string().contains("organization or repository"));
}
