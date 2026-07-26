mod build;
mod clock;
mod error;
mod http;
pub mod kuma;
mod process;
mod registry;

pub use build::{BuildSystem, BuildTarget, ProcessBuildSystem};
pub use clock::{Clock, SystemClock};
pub use error::BlockError;
pub use http::{HttpClient, HttpMethod, HttpResponse, ReqwestHttpClient};
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
pub use kuma::fake::FakeMeshControlPlane;
#[cfg(test)]
pub use process::{FakeInvocation, FakeProcessExecutor, FakeProcessMethod, FakeResponse};
