use std::fs;
use std::io;
use std::path::Path;

const LEGACY_REVIEWS_CLONES_SUBDIR: &str = "reviews/clones";

pub(super) async fn remove_legacy_reviews_clones() -> io::Result<bool> {
    let path = crate::daemon::state::daemon_root().join(LEGACY_REVIEWS_CLONES_SUBDIR);
    tokio::task::spawn_blocking(move || remove_legacy_reviews_clones_at(&path))
        .await
        .map_err(io::Error::other)?
}

fn remove_legacy_reviews_clones_at(path: &Path) -> io::Result<bool> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    if metadata.is_dir() {
        fs::remove_dir_all(path)?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::remove_legacy_reviews_clones_at;

    #[test]
    fn removes_legacy_clone_tree_and_registry() {
        let sandbox = tempfile::tempdir().expect("tempdir");
        let clones = sandbox.path().join("reviews/clones");
        let bare_clone = clones.join("owner_repo.git/objects");
        fs::create_dir_all(&bare_clone).expect("create legacy clone");
        fs::write(clones.join("registry.json"), "{}").expect("write legacy registry");
        fs::write(bare_clone.join("pack"), "legacy").expect("write legacy object");

        assert!(remove_legacy_reviews_clones_at(&clones).expect("remove legacy clones"));
        assert!(!clones.exists());
    }

    #[test]
    fn missing_legacy_clone_tree_is_an_idempotent_noop() {
        let sandbox = tempfile::tempdir().expect("tempdir");
        let clones = sandbox.path().join("reviews/clones");

        assert!(!remove_legacy_reviews_clones_at(&clones).expect("ignore missing clones"));
    }

    #[cfg(unix)]
    #[test]
    fn removes_legacy_symlink_without_traversing_target() {
        use std::os::unix::fs::symlink;

        let sandbox = tempfile::tempdir().expect("tempdir");
        let target = sandbox.path().join("target");
        fs::create_dir_all(&target).expect("create target");
        fs::write(target.join("keep"), "data").expect("write target data");
        let clones = sandbox.path().join("reviews/clones");
        fs::create_dir_all(clones.parent().expect("reviews parent")).expect("create reviews");
        symlink(&target, &clones).expect("create legacy symlink");

        assert!(remove_legacy_reviews_clones_at(&clones).expect("remove legacy symlink"));
        assert!(target.join("keep").exists());
        assert!(!clones.exists());
    }
}
