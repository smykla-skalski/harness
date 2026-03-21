use std::sync::Arc;

use crate::infra::blocks::{
    FakeComposeOrchestrator, FakeContainerRuntime, FakeHttpClient, FakeProcessExecutor,
};

use super::*;

fn block() -> KumaControlPlane {
    KumaControlPlane::new(
        Arc::new(FakeProcessExecutor::new(vec![])),
        Arc::new(FakeHttpClient::new(vec![])),
        Arc::new(FakeContainerRuntime::new()),
        Arc::new(FakeComposeOrchestrator::new()),
    )
}

#[test]
fn api_path_preserves_leading_slash() {
    let kuma = block();
    assert_eq!(kuma.api_path("/meshes").unwrap(), "/meshes");
}

#[test]
fn api_path_adds_leading_slash() {
    let kuma = block();
    assert_eq!(kuma.api_path("meshes").unwrap(), "/meshes");
}

#[test]
fn denied_binaries_contains_kumactl() {
    let kuma = block();
    assert_eq!(kuma.denied_binaries(), &["kumactl"]);
}

#[test]
fn derives_universal_image_from_cp_image() {
    let kuma = block();
    let derived = kuma
        .derive_universal_service_image("docker.io/kumahq/kuma-cp:2.12.0")
        .unwrap();
    assert_eq!(derived, "docker.io/kumahq/kuma-universal:2.12.0");
}
