use super::resource_api_path;

#[test]
fn mesh_resource_uses_top_level_path() {
    assert_eq!(
        resource_api_path("Mesh", "default", None).unwrap(),
        "/meshes/default"
    );
}

#[test]
fn mesh_scoped_resource_defaults_mesh() {
    assert_eq!(
        resource_api_path("MeshTimeout", "demo", None).unwrap(),
        "/meshes/default/meshtimeouts/demo"
    );
}
