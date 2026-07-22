use sha2::{Digest, Sha256};

use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteSourceMaterial,
};
use crate::errors::CliError;
use crate::git::source_bundle_export::GitSourceBundleExport;

#[derive(Debug, Clone)]
pub(crate) struct PreparedRemoteSource {
    pub(crate) source: RemoteSourceMaterial,
    pub(crate) artifacts: RemoteArtifactManifest,
    pub(crate) content: Option<Vec<u8>>,
}

impl PreparedRemoteSource {
    pub(crate) fn repository(&self) -> &str {
        self.source.repository()
    }

    pub(crate) fn repository_snapshot(export: GitSourceBundleExport) -> Result<Self, CliError> {
        let size_bytes = u64::try_from(export.bytes.len())
            .map_err(|_| super::invalid("repository snapshot bundle size overflowed"))?;
        let artifact = RemoteArtifactEntry {
            relative_path: "source/repository.bundle".into(),
            sha256: hex::encode(Sha256::digest(&export.bytes)),
            size_bytes,
            media_type: "application/x-git-bundle".into(),
        };
        let source = RemoteSourceMaterial::repository_snapshot_bundle(
            &export.repository,
            &export.revision,
            artifact.clone(),
        );
        if let RemoteSourceMaterial::RepositorySnapshotBundle { advertised_ref, .. } = &source
            && advertised_ref != &export.advertised_ref
        {
            return Err(super::invalid("repository snapshot advertised ref changed"));
        }
        Ok(Self {
            source,
            artifacts: RemoteArtifactManifest {
                entries: vec![artifact],
            },
            content: Some(export.bytes),
        })
    }
}
