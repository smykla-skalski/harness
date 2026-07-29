use sha2::{Digest as _, Sha256};

use super::remote_source_bundle_prior::{TaskBoardRemotePriorPhaseBundle, consistent_bundle};
use crate::daemon::task_board_remote_transport::wire::RemoteArtifactEntry;

#[test]
fn prior_bundle_loader_accepts_each_single_readable_origin() {
    let origin = bundle("origin", b"portable implementation");
    assert_eq!(
        consistent_bundle(vec![origin.clone()]).expect("accept result-origin bytes"),
        Some(origin.clone())
    );
    assert_eq!(
        consistent_bundle(vec![origin.clone()]).expect("accept materialized bytes"),
        Some(origin)
    );
    assert_eq!(
        consistent_bundle(Vec::new()).expect("both pruned means no source"),
        None
    );
}

#[test]
fn prior_bundle_loader_accepts_identical_copies_and_rejects_disagreement() {
    let origin = bundle("origin", b"portable implementation");
    let mut materialized = origin.clone();
    materialized.origin_assignment_id = "materialized".into();
    materialized.origin_fencing_epoch = 2;
    let loaded = consistent_bundle(vec![origin.clone(), materialized])
        .expect("identical readable copies agree")
        .expect("one canonical source");
    assert_eq!(loaded.content, origin.content);
    assert_eq!(loaded.artifact, origin.artifact);

    let contradictory = bundle("materialized", b"different implementation");
    let error = consistent_bundle(vec![origin, contradictory])
        .expect_err("contradictory readable copies must fail closed");
    assert!(error.to_string().contains("copies disagree"));
}

fn bundle(origin: &str, content: &[u8]) -> TaskBoardRemotePriorPhaseBundle {
    TaskBoardRemotePriorPhaseBundle {
        origin_assignment_id: origin.into(),
        origin_fencing_epoch: 1,
        repository: "example/harness".into(),
        base_revision: "1".repeat(40),
        result_revision: "2".repeat(40),
        artifact: RemoteArtifactEntry {
            relative_path: "result/implementation.bundle".into(),
            sha256: hex::encode(Sha256::digest(content)),
            size_bytes: u64::try_from(content.len()).expect("bundle size"),
            media_type: "application/x-git-bundle".into(),
        },
        content: content.to_vec(),
    }
}
