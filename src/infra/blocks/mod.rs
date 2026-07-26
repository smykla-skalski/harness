mod build;
mod clock;
mod error;
mod http;
mod kubernetes;
pub mod kuma;
mod process;
mod registry;

pub use build::{BuildSystem, BuildTarget, ProcessBuildSystem};
pub use clock::{Clock, SystemClock};
pub use error::BlockError;
pub use http::{HttpClient, HttpMethod, HttpResponse, ReqwestHttpClient};
#[cfg(feature = "k3d")]
pub use kubernetes::K3dClusterManager;
#[cfg(feature = "kubernetes")]
pub use kubernetes::KubeRuntime;
pub use kubernetes::{
    ExecRequest, KubectlRuntime, KubernetesRuntime, KubernetesRuntimeBackend, LocalClusterManager,
    ManifestDiff, PodSnapshot, SelectedKubernetesBackends, kubernetes_backend_from_env,
    kubernetes_backends_from_env, kubernetes_runtime_from_env,
};
#[cfg(feature = "kuma")]
pub use kuma::KumaControlPlane;
pub use kuma::MeshControlPlane;
pub use process::{ProcessExecutor, StdProcessExecutor};
pub use registry::BlockRequirement;

#[cfg(test)]
pub use build::FakeBuildSystem;
#[cfg(test)]
pub use clock::FakeClock;
#[cfg(test)]
pub use http::FakeHttpClient;
#[cfg(test)]
pub use kubernetes::{
    FakeK3dInvocation, FakeKubernetesInvocation, FakeKubernetesRuntime, FakeLocalClusterManager,
};
#[cfg(test)]
pub use kuma::fake::FakeMeshControlPlane;
#[cfg(test)]
pub use process::{FakeInvocation, FakeProcessExecutor, FakeProcessMethod, FakeResponse};
