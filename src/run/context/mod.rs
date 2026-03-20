mod aggregate;
pub mod cleanup;
mod command_env;
mod current;
mod layout;
mod metadata;
mod preflight;
mod repository;
mod snapshots;
#[cfg(test)]
mod tests;
mod validated;

pub use aggregate::{RunAggregate, RunContext};
pub use cleanup::{CleanupManifest, CleanupResource};
pub use command_env::CommandEnv;
pub use current::{CurrentRunPointer, CurrentRunRecord};
pub use layout::RunLayout;
pub use metadata::RunMetadata;
pub use preflight::PreflightArtifact;
pub use repository::{RunRepository, RunRepositoryPort};
pub use snapshots::{
    ArtifactSnapshot, NodeCheckRecord, NodeCheckSnapshot, ToolCheckRecord, ToolCheckSnapshot,
};
pub use validated::ValidatedRunLayout;

#[cfg(test)]
pub use repository::InMemoryRunRepository;
