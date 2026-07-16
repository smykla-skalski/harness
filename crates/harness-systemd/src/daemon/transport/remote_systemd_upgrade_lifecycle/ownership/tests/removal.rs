use std::fs;
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use serde_json::{Value, json};

use super::{BindMode, EMPTY_INVENTORY, Fixture};

#[test]
fn durable_removal_retains_a_private_empty_registry() {
    let fixture = Fixture::new();
    let mut claimed = fixture
        .acquire("alpha")
        .bind(&fixture.binary, BindMode::InstallOrMatch, &EMPTY_INVENTORY)
        .expect("claim");
    claimed
        .persist_claim(&EMPTY_INVENTORY)
        .expect("persist claim");

    let locked = claimed.remove_claim().expect("durable removal");
    assert!(locked.claim_for_unit().expect("empty lookup").is_none());
    assert_private_empty_registry(&fixture);
}

fn assert_private_empty_registry(fixture: &Fixture) {
    let registry_path = fixture.root.join(".binary-claims.json");
    let metadata = fs::symlink_metadata(&registry_path).expect("registry metadata");
    assert!(metadata.is_file());
    assert_eq!(metadata.mode() & 0o7777, 0o600);
    assert_eq!(metadata.nlink(), 1);
    let document: Value =
        serde_json::from_slice(&fs::read(&registry_path).expect("registry bytes"))
            .expect("registry JSON");
    assert_eq!(document["registry_version"], 1);
    assert_eq!(document["claims"], json!([]));
    assert_no_registry_temporaries(&fixture.root);
}

fn assert_no_registry_temporaries(root: &Path) {
    let has_temporary = fs::read_dir(root)
        .expect("root entries")
        .map(|entry| entry.expect("root entry").file_name())
        .any(|name| {
            name.to_string_lossy()
                .starts_with(".binary-claims.json.tmp-")
        });
    assert!(!has_temporary);
}
