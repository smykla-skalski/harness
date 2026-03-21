use std::borrow::Cow;
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::kernel::topology::ClusterSpec;

/// Borrowed Kubernetes runtime details for a tracked run.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct KubernetesRuntime<'a> {
    spec: &'a ClusterSpec,
}

impl<'a> KubernetesRuntime<'a> {
    pub(crate) fn from_spec(spec: &'a ClusterSpec) -> Self {
        Self { spec }
    }

    /// Resolve the effective kubeconfig for an operation.
    ///
    /// # Errors
    /// Returns `CliError` when the requested cluster is not tracked.
    pub fn resolve_kubeconfig(
        self,
        explicit: Option<&'a str>,
        cluster: Option<&str>,
    ) -> Result<Cow<'a, Path>, CliError> {
        if let Some(path) = explicit {
            return Ok(Cow::Borrowed(Path::new(path)));
        }
        if let Some(cluster_name) = cluster {
            return self
                .spec
                .member(cluster_name)
                .map(|member| Cow::Borrowed(Path::new(member.kubeconfig.as_str())))
                .ok_or_else(|| CliErrorKind::missing_run_context_value("kubeconfig").into());
        }
        Ok(Cow::Borrowed(Path::new(self.spec.primary_kubeconfig())))
    }
}
