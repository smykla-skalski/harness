mod build;
mod clock;
mod compose;
mod docker;
mod envoy;
mod error;
mod helm;
mod http;
mod kubernetes;
pub mod kuma;
mod process;
mod registry;

pub use build::{BuildSystem, BuildTarget, ProcessBuildSystem};
pub use clock::{Clock, SystemClock};
pub use compose::{
    ComposeFile, ComposeOrchestrator, ComposeTopology, HealthcheckSpec, NetworkSpec,
    ServiceDependency, ServiceSpec,
};
#[cfg(feature = "compose")]
pub use compose::DockerComposeOrchestrator;
pub use docker::{ContainerConfig, ContainerRuntime, ContainerSnapshot, DockerContainerRuntime};
pub use envoy::{CaptureRequest, EnvoyIntrospector, ProxyIntrospector};
pub use error::BlockError;
pub use helm::{HelmSetting, PackageDeployResult, PackageDeployer};
#[cfg(feature = "helm")]
pub use helm::HelmDeployer;
pub use http::{HttpClient, HttpMethod, HttpResponse, ReqwestHttpClient};
pub use kubernetes::{KubectlOperator, KubernetesOperator, LocalClusterManager, PodSnapshot};
#[cfg(feature = "k3d")]
pub use kubernetes::K3dClusterManager;
pub use kuma::MeshControlPlane;
#[cfg(feature = "kuma")]
pub use kuma::KumaControlPlane;
pub use process::{ProcessExecutor, StdProcessExecutor};
pub use registry::{BlockRegistry, BlockRequirement};

#[cfg(test)]
pub use build::FakeBuildSystem;
#[cfg(test)]
pub use clock::FakeClock;
#[cfg(test)]
pub use compose::FakeComposeOrchestrator;
#[cfg(test)]
pub use docker::FakeContainerRuntime;
#[cfg(test)]
pub use envoy::FakeProxyIntrospector;
#[cfg(test)]
pub use helm::FakePackageDeployer;
#[cfg(test)]
pub use http::FakeHttpClient;
#[cfg(test)]
pub use kubernetes::{
    FakeK3dInvocation, FakeKubectlInvocation, FakeKubernetesOperator, FakeLocalClusterManager,
};
#[cfg(test)]
pub use kuma::fake::FakeMeshControlPlane;
#[cfg(test)]
pub use process::{FakeInvocation, FakeProcessExecutor, FakeProcessMethod, FakeResponse};
