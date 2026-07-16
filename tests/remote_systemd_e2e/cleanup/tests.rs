use std::cell::{Cell, RefCell};
use std::ffi::OsStr;

use super::{
    ARMED_TRANSACTION_ERROR, INTERRUPTED_ROTATION_ERROR, PENDING_GENERATION_ERROR,
    is_runtime_token_directory_name, release_managed_install_with, reset_failed_reports_unloaded,
    reset_failed_unloaded_message, transaction_cleanup_required,
};

#[test]
fn runtime_token_directory_names_require_a_lowercase_simple_uuid() {
    assert!(is_runtime_token_directory_name(OsStr::new(
        ".harness-start-permit-00112233445566778899aabbccddeeff"
    )));
    for name in [
        ".harness-start-permit-00112233445566778899aabbccddeef",
        ".harness-start-permit-00112233445566778899aabbccddeefg",
        ".harness-start-permit-00112233445566778899AABBCCDDEEFF",
        ".harness-start-permit-00112233-4455-6677-8899-aabbccddeeff",
        ".harness-start-permit-00112233445566778899aabbccddeeff.token",
        "unrelated-00112233445566778899aabbccddeeff",
    ] {
        assert!(!is_runtime_token_directory_name(OsStr::new(name)));
    }
}

#[test]
fn managed_uninstall_retries_only_after_disarming() {
    let attempts = Cell::new(0_u8);
    let actions = RefCell::new(Vec::new());
    release_managed_install_with(
        || {
            actions.borrow_mut().push("uninstall");
            attempts.set(attempts.get().saturating_add(1));
            if attempts.get() == 1 {
                Err(format!("{ARMED_TRANSACTION_ERROR} in test store"))
            } else {
                Ok(())
            }
        },
        || {
            actions.borrow_mut().push("disarm");
            Ok(())
        },
    )
    .expect("retry managed uninstall");
    let expected = ["uninstall", "disarm", "uninstall"];
    assert_eq!(actions.into_inner(), expected);
}

#[test]
fn every_transaction_blocker_requires_cleanup() {
    for message in [
        ARMED_TRANSACTION_ERROR,
        PENDING_GENERATION_ERROR,
        INTERRUPTED_ROTATION_ERROR,
    ] {
        assert!(transaction_cleanup_required(&format!(
            "command failed: {message}"
        )));
    }
}

#[test]
fn managed_uninstall_preserves_both_failures() {
    let actions = RefCell::new(Vec::new());
    let error = release_managed_install_with(
        || {
            actions.borrow_mut().push("uninstall");
            Err(format!("{ARMED_TRANSACTION_ERROR}: uninstall failed"))
        },
        || {
            actions.borrow_mut().push("disarm");
            Ok(())
        },
    )
    .expect_err("retry failure");
    let expected = ["uninstall", "disarm", "uninstall"];
    assert_eq!(actions.into_inner(), expected);
    assert!(error.contains("uninstall failed"));
    assert!(error.contains("retry after removing interrupted transaction failed"));
}

#[test]
fn managed_uninstall_preserves_disarm_failure() {
    let actions = RefCell::new(Vec::new());
    let error = release_managed_install_with(
        || {
            actions.borrow_mut().push("uninstall");
            Err(format!("{PENDING_GENERATION_ERROR}: uninstall failed"))
        },
        || {
            actions.borrow_mut().push("disarm");
            Err("transaction directory could not be removed".to_string())
        },
    )
    .expect_err("disarm failure");
    assert_eq!(actions.into_inner(), ["uninstall", "disarm"]);
    assert!(error.contains("uninstall failed"));
    assert!(error.contains("transaction directory could not be removed"));
}

#[test]
fn managed_uninstall_does_not_disarm_for_unrelated_failures() {
    let actions = RefCell::new(Vec::new());
    let error = release_managed_install_with(
        || {
            actions.borrow_mut().push("uninstall");
            Err("another remote systemd lifecycle operation is running".to_string())
        },
        || {
            actions.borrow_mut().push("disarm");
            Ok(())
        },
    )
    .expect_err("unrelated failure");
    assert_eq!(actions.into_inner(), ["uninstall"]);
    assert!(error.contains("another remote systemd lifecycle operation"));
}

#[test]
fn reset_failed_accepts_only_the_exact_unloaded_unit_error() {
    let unit = "harness-remote-e2e.service";
    let unloaded = format!("{}\n", reset_failed_unloaded_message(unit));
    assert!(reset_failed_reports_unloaded(unit, unloaded.as_bytes()));
    assert!(!reset_failed_reports_unloaded(
        unit,
        b"Failed to connect to bus: Permission denied\n"
    ));
}
