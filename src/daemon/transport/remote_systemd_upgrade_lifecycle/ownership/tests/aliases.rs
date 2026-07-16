use std::fs::{self, Permissions};
use std::os::unix::fs::{PermissionsExt as _, symlink};
use std::path::Path;

use super::{BindMode, Fixture, empty_inventory};

#[test]
fn bind_rejects_a_symlinked_parent_alias_reserved_by_an_absent_unit() {
    let fixture = Fixture::new();
    let mut alpha = fixture
        .acquire("alpha")
        .bind(&fixture.binary, BindMode::InstallOrMatch, &empty_inventory)
        .expect("alpha claim");
    alpha
        .persist_claim(&empty_inventory)
        .expect("persist alpha claim");
    drop(alpha);

    let binary_parent = fixture.binary.parent().expect("binary parent");
    let alias_parent = binary_parent.join("binary-parent-alias");
    symlink(binary_parent, &alias_parent).expect("binary parent alias");
    let alias_binary = alias_parent.join(fixture.binary.file_name().expect("binary filename"));
    let error = fixture
        .acquire("beta")
        .bind(&alias_binary, BindMode::InstallOrMatch, &empty_inventory)
        .expect_err("aliased ownership entry");

    assert!(
        error
            .to_string()
            .contains("ownership target already claimed by unit alpha")
    );
}

#[test]
fn recheck_rejects_a_symlinked_parent_retarget() {
    let fixture = Fixture::new();
    let binary_parent = fixture.binary.parent().expect("binary parent");
    let first_parent = binary_parent.join("first");
    let second_parent = binary_parent.join("second");
    fs::create_dir(&first_parent).expect("first parent");
    fs::create_dir(&second_parent).expect("second parent");
    let first_binary = first_parent.join("harness");
    let second_binary = second_parent.join("harness");
    create_executable(&first_binary, b"first");
    create_executable(&second_binary, b"second");
    let alias_parent = binary_parent.join("active-parent");
    symlink(&first_parent, &alias_parent).expect("first alias target");
    let alias_binary = alias_parent.join("harness");
    let mut claimed = fixture
        .acquire("alpha")
        .bind(&alias_binary, BindMode::InstallOrMatch, &empty_inventory)
        .expect("alias claim");
    claimed
        .persist_claim(&empty_inventory)
        .expect("persist alias claim");

    fs::remove_file(&alias_parent).expect("remove first alias");
    symlink(&second_parent, &alias_parent).expect("second alias target");
    let error = claimed
        .recheck(&empty_inventory)
        .expect_err("retargeted alias");

    assert!(
        error
            .to_string()
            .contains("binary ownership target changed")
    );
}

#[test]
fn bind_rejects_a_distinct_hard_link_to_a_claimed_current_file() {
    let fixture = Fixture::new();
    let mut alpha = fixture
        .acquire("alpha")
        .bind(&fixture.binary, BindMode::InstallOrMatch, &empty_inventory)
        .expect("alpha claim");
    alpha
        .persist_claim(&empty_inventory)
        .expect("persist alpha claim");
    drop(alpha);
    let hard_link = fixture.binary.with_file_name("hard-linked-harness");
    fs::hard_link(&fixture.binary, &hard_link).expect("hard-linked binary");

    let error = fixture
        .acquire("beta")
        .bind(&hard_link, BindMode::InstallOrMatch, &empty_inventory)
        .expect_err("shared current inode");

    assert!(
        error
            .to_string()
            .contains("ownership target already claimed by unit alpha")
    );
}

fn create_executable(path: &Path, contents: &[u8]) {
    fs::write(path, contents).expect("binary contents");
    fs::set_permissions(path, Permissions::from_mode(0o700)).expect("binary mode");
}
