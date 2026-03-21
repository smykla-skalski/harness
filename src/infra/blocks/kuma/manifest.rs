use crate::infra::blocks::BlockError;

use super::defaults::DEFAULT_MESH;

/// Build the Kuma REST API path for a resource manifest.
///
/// # Errors
///
/// Returns `BlockError` if `resource_type` or `name` is empty.
pub fn resource_api_path(
    resource_type: &str,
    name: &str,
    mesh: Option<&str>,
) -> Result<String, BlockError> {
    let resource_type = resource_type.trim();
    if resource_type.is_empty() {
        return Err(BlockError::message(
            "kuma",
            "resource_api_path",
            "resource_type must not be empty",
        ));
    }
    let name = name.trim();
    if name.is_empty() {
        return Err(BlockError::message(
            "kuma",
            "resource_api_path",
            "name must not be empty",
        ));
    }

    let collection = resource_type.to_ascii_lowercase();
    if collection == "mesh" {
        return Ok(format!("/meshes/{name}"));
    }

    let mesh_name = mesh
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(DEFAULT_MESH);
    Ok(format!("/meshes/{mesh_name}/{collection}s/{name}"))
}

#[cfg(test)]
#[path = "manifest/tests.rs"]
mod tests;
