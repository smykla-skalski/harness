mod aggregate;
pub mod cleanup;
mod command_env;
mod layout;
mod metadata;
mod preflight;
mod repository;
mod snapshots;
#[cfg(all(test, not(feature = "standalone-worker")))]
mod tests;

pub use aggregate::{RunAggregate, RunContext};
pub use cleanup::{CleanupManifest, CleanupResource};
pub use command_env::CommandEnv;
pub use layout::RunLayout;
pub use metadata::RunMetadata;
pub use preflight::PreflightArtifact;
pub use repository::{RunRepository, RunRepositoryPort};
pub use snapshots::{
    ArtifactSnapshot, NodeCheckRecord, NodeCheckSnapshot, ToolCheckRecord, ToolCheckSnapshot,
};

#[cfg(test)]
pub use repository::InMemoryRunRepository;
