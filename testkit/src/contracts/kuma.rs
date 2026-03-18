use std::path::Path;

use harness::infra::blocks::MeshControlPlane;

/// `system_namespace()` returns a non-empty string.
///
/// # Panics
/// Panics if the namespace is empty.
pub fn contract_system_namespace_non_empty(kuma: &dyn MeshControlPlane) {
    let ns = kuma.system_namespace();
    assert!(!ns.is_empty(), "system_namespace should not be empty");
}

/// Port getters return non-zero values.
///
/// # Panics
/// Panics if any port is zero.
pub fn contract_ports_are_nonzero(kuma: &dyn MeshControlPlane) {
    assert!(kuma.api_port() > 0, "api_port should be non-zero");
    assert!(kuma.xds_port() > 0, "xds_port should be non-zero");
    assert!(
        kuma.envoy_admin_port() > 0,
        "envoy_admin_port should be non-zero"
    );
}

/// `api_path` with a non-empty relative path returns a path starting with `/`.
///
/// # Panics
/// Panics if `api_path` returns an error.
pub fn contract_api_path_prepends_slash(kuma: &dyn MeshControlPlane) {
    let result = kuma.api_path("meshes").expect("api_path should succeed");
    assert!(result.starts_with('/'), "api_path should start with /");
}

/// `api_path` preserves an existing leading slash.
///
/// # Panics
/// Panics if `api_path` returns an error.
pub fn contract_api_path_preserves_leading_slash(kuma: &dyn MeshControlPlane) {
    let result = kuma.api_path("/meshes").expect("api_path should succeed");
    assert_eq!(result, "/meshes");
}

/// `api_path` with an empty string returns an error.
///
/// # Panics
/// Panics if empty input does not produce an error.
pub fn contract_api_path_rejects_empty(kuma: &dyn MeshControlPlane) {
    let result = kuma.api_path("");
    assert!(result.is_err(), "api_path('') should be an error");
}

/// `is_cp_image` returns true for standard Kuma CP image references.
///
/// # Panics
/// Panics if the standard image is not recognized.
pub fn contract_is_cp_image_recognizes_standard_image(kuma: &dyn MeshControlPlane) {
    assert!(
        kuma.is_cp_image("docker.io/kumahq/kuma-cp:2.12.0"),
        "should recognize kuma-cp image"
    );
}

/// `derive_universal_service_image` maps a CP image to the universal image.
///
/// # Panics
/// Panics if the derivation fails.
pub fn contract_derive_universal_image(kuma: &dyn MeshControlPlane) {
    let derived = kuma
        .derive_universal_service_image("docker.io/kumahq/kuma-cp:2.12.0")
        .expect("derive should succeed");
    assert!(
        derived.contains("kuma-universal"),
        "derived image should contain 'kuma-universal', got: {derived}"
    );
    assert!(
        derived.contains("2.12.0"),
        "derived image should preserve the tag, got: {derived}"
    );
}

/// `default_kumactl_path` returns a path ending with `kumactl`.
///
/// # Panics
/// Panics if the path has no file name component.
pub fn contract_default_kumactl_path(kuma: &dyn MeshControlPlane) {
    let path = kuma.default_kumactl_path(Path::new("/repo"));
    let name = path.file_name().expect("should have a file name");
    assert_eq!(name, "kumactl");
}

/// Mode strings return non-empty values.
///
/// # Panics
/// Panics if any mode string is empty.
pub fn contract_modes_non_empty(kuma: &dyn MeshControlPlane) {
    assert!(!kuma.zone_mode().is_empty());
    assert!(!kuma.global_mode().is_empty());
    assert!(!kuma.universal_environment().is_empty());
}

#[cfg(test)]
mod tests {
    // Production tests require Kuma infrastructure - no production tests here.
    // Fake-based contract tests live in src/blocks/kuma/ within the harness crate.
}
