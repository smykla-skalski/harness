mod build;
mod compose;
mod docker;
mod error;
mod helm;
mod http;
mod kubernetes;
pub mod kuma;
mod process;
mod registry;

pub use build::{BuildSystem, BuildTarget, ProcessBuildSystem};
pub use compose::{
    ComposeFile, ComposeOrchestrator, ComposeTopology, DockerComposeOrchestrator, HealthcheckSpec,
    NetworkSpec, ServiceDependency, ServiceSpec,
};
pub use docker::{ContainerConfig, ContainerRuntime, ContainerSnapshot, DockerContainerRuntime};
pub use error::BlockError;
pub use helm::{HelmDeployer, HelmSetting, PackageDeployResult, PackageDeployer};
pub use http::{HttpClient, HttpMethod, HttpResponse, ReqwestHttpClient};
pub use kubernetes::{
    K3dClusterManager, KubectlOperator, KubernetesOperator, LocalClusterManager, PodSnapshot,
};
pub use kuma::{KumaControlPlane, MeshControlPlane};
pub use process::{ProcessExecutor, StdProcessExecutor};
pub use registry::{BlockRegistry, BlockRequirement};

#[cfg(test)]
pub use compose::FakeComposeOrchestrator;
#[cfg(test)]
pub use docker::FakeContainerRuntime;
#[cfg(test)]
pub use helm::FakePackageDeployer;
#[cfg(test)]
pub use http::FakeHttpClient;
#[cfg(test)]
pub use kubernetes::{
    FakeK3dInvocation, FakeKubectlInvocation, FakeKubernetesOperator, FakeLocalClusterManager,
};
#[cfg(test)]
pub use process::{FakeInvocation, FakeProcessExecutor, FakeProcessMethod, FakeResponse};
