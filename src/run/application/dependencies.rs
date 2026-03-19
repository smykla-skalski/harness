use std::collections::BTreeSet;
use std::fmt;
use std::sync::Arc;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::{
    BlockError, BlockRequirement, ContainerRuntime, DockerContainerRuntime, StdProcessExecutor,
};

/// Explicit infrastructure required by tracked-run use cases.
#[derive(Clone)]
pub(crate) struct RunDependencies {
    docker: Option<Arc<dyn ContainerRuntime>>,
    requirements: RequirementSupport,
}

impl fmt::Debug for RunDependencies {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RunDependencies")
            .field("has_docker", &self.docker.is_some())
            .field("requirements", &self.requirements)
            .finish()
    }
}

impl RunDependencies {
    #[must_use]
    pub(crate) fn production() -> Self {
        let process = Arc::new(StdProcessExecutor);
        let docker: Arc<dyn ContainerRuntime> = Arc::new(DockerContainerRuntime::new(process));
        Self {
            docker: Some(docker),
            requirements: RequirementSupport::production(),
        }
    }

    #[cfg(test)]
    #[must_use]
    pub(crate) fn for_tests(docker: Option<Arc<dyn ContainerRuntime>>) -> Self {
        Self {
            docker,
            requirements: RequirementSupport::production(),
        }
    }

    #[must_use]
    pub(crate) fn has_docker(&self) -> bool {
        self.docker.is_some()
    }

    #[must_use]
    pub(crate) fn docker(&self) -> Option<&dyn ContainerRuntime> {
        self.docker.as_deref()
    }

    /// Return docker or a typed missing-context error.
    ///
    /// # Errors
    /// Returns `CliError` when docker support is unavailable.
    pub(crate) fn docker_required(&self) -> Result<&dyn ContainerRuntime, CliError> {
        self.docker
            .as_deref()
            .ok_or_else(|| CliErrorKind::missing_run_context_value("docker").into())
    }

    /// Validate suite-declared requirement names against supported run capabilities.
    ///
    /// # Errors
    /// Returns `CliError` for unknown or unsupported requirement names.
    pub(crate) fn validate_requirement_names(
        &self,
        requirements: &[String],
    ) -> Result<(), CliError> {
        self.requirements.validate_names(requirements)
    }
}

#[derive(Debug, Clone)]
struct RequirementSupport {
    supported: BTreeSet<BlockRequirement>,
}

impl RequirementSupport {
    #[must_use]
    fn production() -> Self {
        let mut supported = BTreeSet::from([
            BlockRequirement::Docker,
            BlockRequirement::Kubernetes,
            BlockRequirement::Build,
        ]);

        #[cfg(feature = "compose")]
        supported.insert(BlockRequirement::Compose);
        #[cfg(feature = "k3d")]
        supported.insert(BlockRequirement::K3d);
        #[cfg(feature = "helm")]
        supported.insert(BlockRequirement::Helm);
        #[cfg(feature = "kuma")]
        supported.insert(BlockRequirement::Kuma);

        Self { supported }
    }

    #[cfg(test)]
    #[must_use]
    fn with_supported(supported: impl IntoIterator<Item = BlockRequirement>) -> Self {
        Self {
            supported: supported.into_iter().collect(),
        }
    }

    fn validate_names(&self, requirements: &[String]) -> Result<(), CliError> {
        let parsed = requirements
            .iter()
            .map(|name| BlockRequirement::parse(name))
            .collect::<Result<Vec<_>, _>>()?;
        let missing = parsed
            .into_iter()
            .filter(|requirement| !self.supported.contains(requirement))
            .map(BlockRequirement::as_str)
            .collect::<Vec<_>>();

        if missing.is_empty() {
            return Ok(());
        }

        Err(BlockError::message(
            "run-dependencies",
            "validate requirements",
            format!("missing required blocks: {}", missing.join(", ")),
        )
        .into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn production_support_includes_core_run_blocks() {
        let deps = RunDependencies::production();
        for requirement in ["docker", "kubernetes", "build"] {
            assert!(
                deps.validate_requirement_names(&[requirement.to_string()])
                    .is_ok(),
                "missing supported requirement: {requirement}"
            );
        }
        assert!(
            deps.validate_requirement_names(&["envoy".to_string()])
                .is_err()
        );
    }

    #[test]
    fn validate_requirement_names_rejects_unknown_names() {
        let support = RequirementSupport::with_supported([BlockRequirement::Docker]);
        let error = support
            .validate_names(&["not-a-block".to_string()])
            .expect_err("expected unknown requirement to fail");
        assert_eq!(
            error.details(),
            Some("unknown block requirement: not-a-block")
        );
    }

    #[test]
    fn validate_requirement_names_reports_missing_block() {
        let support = RequirementSupport::with_supported([BlockRequirement::Docker]);
        let error = support
            .validate_names(&["kubernetes".to_string()])
            .expect_err("expected unsupported requirement to fail");
        assert_eq!(error.details(), Some("missing required blocks: kubernetes"));
    }
}
