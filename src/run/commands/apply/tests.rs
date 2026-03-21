use super::*;

#[test]
fn kuma_api_path_mesh_resource() {
    assert_eq!(
        resource_api_path("Mesh", "my-mesh", None).unwrap(),
        "/meshes/my-mesh"
    );
    assert_eq!(
        resource_api_path("Mesh", "default", Some("ignored")).unwrap(),
        "/meshes/default"
    );
}

#[test]
fn kuma_api_path_mesh_scoped_policy() {
    assert_eq!(
        resource_api_path("MeshTrafficPermission", "allow-all", Some("default")).unwrap(),
        "/meshes/default/meshtrafficpermissions/allow-all"
    );
}

#[test]
fn kuma_api_path_simple_type() {
    assert_eq!(
        resource_api_path("Dataplane", "dp-1", Some("default")).unwrap(),
        "/meshes/default/dataplanes/dp-1"
    );
}

#[test]
fn kuma_api_path_defaults_to_default_mesh() {
    assert_eq!(
        resource_api_path("MeshTimeout", "mt-1", None).unwrap(),
        "/meshes/default/meshtimeouts/mt-1"
    );
}
