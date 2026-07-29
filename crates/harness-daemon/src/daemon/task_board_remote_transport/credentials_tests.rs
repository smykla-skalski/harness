use super::credentials::{
    RemoteExecutionCredentialError, RemoteExecutionCredentialResolver, parse_reference_for_tests,
};

#[test]
fn environment_credentials_are_resolved_per_call_and_redacted() {
    temp_env::with_var(
        "HARNESS_REMOTE_EXECUTOR_TEST_TOKEN",
        Some("first-secret"),
        || {
            let first = RemoteExecutionCredentialResolver::resolve(
                "env://HARNESS_REMOTE_EXECUTOR_TEST_TOKEN",
            )
            .expect("first credential");
            assert_eq!(first.expose(), "first-secret");
            assert!(!format!("{first:?}").contains("first-secret"));

            temp_env::with_var(
                "HARNESS_REMOTE_EXECUTOR_TEST_TOKEN",
                Some("rotated-secret"),
                || {
                    let rotated = RemoteExecutionCredentialResolver::resolve(
                        "env://HARNESS_REMOTE_EXECUTOR_TEST_TOKEN",
                    )
                    .expect("rotated credential");
                    assert_eq!(rotated.expose(), "rotated-secret");
                },
            );
        },
    );
}

#[test]
fn credential_references_are_structured_and_fail_closed() {
    for valid in [
        "env://HARNESS_REMOTE_TOKEN",
        "keychain://io.harness.remote/executor-1",
    ] {
        parse_reference_for_tests(valid).expect("valid reference");
    }
    for invalid in [
        "env://",
        "env://BAD-NAME",
        "keychain://service",
        "keychain://service/account/extra",
        "https://example.com/token",
    ] {
        assert_eq!(
            parse_reference_for_tests(invalid).expect_err("invalid reference"),
            RemoteExecutionCredentialError::InvalidReference
        );
    }
    for unsupported in ["op://vault/item/field", "secret://remote/token"] {
        assert_eq!(
            parse_reference_for_tests(unsupported).expect_err("unsupported reference"),
            RemoteExecutionCredentialError::UnsupportedReference
        );
    }
}

#[test]
fn credential_errors_never_include_secret_values() {
    temp_env::with_var(
        "HARNESS_REMOTE_EXECUTOR_BAD_TOKEN",
        Some("secret with whitespace"),
        || {
            let error = RemoteExecutionCredentialResolver::resolve(
                "env://HARNESS_REMOTE_EXECUTOR_BAD_TOKEN",
            )
            .expect_err("whitespace credential denied");
            assert_eq!(error, RemoteExecutionCredentialError::InvalidCredential);
            assert!(!error.to_string().contains("secret with whitespace"));
            assert!(!format!("{error:?}").contains("secret with whitespace"));
        },
    );
}
