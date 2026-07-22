use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{RemoteArtifactEntry, RemoteSourceMaterial};

pub(in super::super) struct SourceBundleCoordinates<'a> {
    pub(in super::super) kind: &'static str,
    pub(in super::super) repository: &'a str,
    pub(in super::super) base_revision: &'a str,
    pub(in super::super) result_revision: &'a str,
    pub(in super::super) advertised_ref: &'a str,
    pub(in super::super) bundle: &'a RemoteArtifactEntry,
}

pub(in super::super) fn source_bundle_coordinates(
    source: &RemoteSourceMaterial,
) -> Result<SourceBundleCoordinates<'_>, CliError> {
    match source {
        RemoteSourceMaterial::PriorPhaseBundle {
            repository,
            base_revision,
            revision,
            advertised_ref,
            bundle,
            ..
        } => Ok(SourceBundleCoordinates {
            kind: "prior_phase_bundle",
            repository,
            base_revision,
            result_revision: revision,
            advertised_ref,
            bundle,
        }),
        RemoteSourceMaterial::RepositorySnapshotBundle {
            repository,
            revision,
            advertised_ref,
            bundle,
            ..
        } => Ok(SourceBundleCoordinates {
            kind: "repository_snapshot_bundle",
            repository,
            base_revision: revision,
            result_revision: revision,
            advertised_ref,
            bundle,
        }),
        RemoteSourceMaterial::Repository { .. } => Err(db_error(
            "remote source bundle upload has repository source",
        )),
    }
}
