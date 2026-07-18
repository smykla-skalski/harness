use super::{parse_publication_url, reconcile_publication_number};

#[test]
fn ambiguous_publication_without_identity_fails_closed() {
    let error = reconcile_publication_number(None, None)
        .expect_err("identity-less recovery must not republish");

    assert!(
        error
            .to_string()
            .contains("identity is unavailable after an ambiguous outcome")
    );
}

#[test]
fn publication_identity_must_match_the_frozen_pull_request() {
    let error = reconcile_publication_number(Some(42), Some(41))
        .expect_err("mismatched publication identity");

    assert!(
        error
            .to_string()
            .contains("changed its frozen pull request")
    );
    assert_eq!(
        reconcile_publication_number(Some(42), Some(42)).expect("exact identity"),
        42
    );
}

#[test]
fn publication_url_parsing_is_canonical() {
    assert_eq!(
        parse_publication_url("https://github.com/example/compass/pull/42").expect("canonical URL"),
        ("example/compass".into(), 42)
    );
    assert!(parse_publication_url("https://example.com/example/compass/pull/42").is_err());
}
