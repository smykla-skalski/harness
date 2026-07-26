use std::sync::Arc;

use super::super::PairingLocks;

#[test]
fn active_pairing_requests_share_one_account_lock() {
    let locks = PairingLocks::default();

    let first = locks.for_account("account");
    let second = locks.for_account("account");

    assert!(Arc::ptr_eq(&first, &second));
}

#[test]
fn inactive_pairing_locks_are_pruned() {
    let locks = PairingLocks::default();
    let inactive = locks.for_account("inactive");
    drop(inactive);

    let active = locks.for_account("active");

    let accounts = locks.accounts.lock().expect("pairing locks");
    assert_eq!(accounts.len(), 1);
    assert!(accounts.contains_key("active"));
    drop(accounts);
    drop(active);
}
