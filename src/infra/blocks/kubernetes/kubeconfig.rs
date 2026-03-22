use std::path::Path;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use fs_err as fs;
use kube::config::{Kubeconfig, NamedAuthInfo, NamedCluster};
use serde_json::{Map, Value};

use crate::infra::blocks::BlockError;

pub(crate) fn flatten_selected_kubeconfig(
    path: &Path,
    context: Option<&str>,
) -> Result<String, BlockError> {
    let kubeconfig = Kubeconfig::read_from(path)
        .map_err(|error| BlockError::new("kubernetes", "read kubeconfig", error))?;

    let context_name = context
        .map(str::to_string)
        .or_else(|| kubeconfig.current_context.clone())
        .ok_or_else(|| {
            BlockError::message(
                "kubernetes",
                "flatten kubeconfig",
                "current context is not set",
            )
        })?;

    let named_context = kubeconfig
        .contexts
        .iter()
        .find(|entry| entry.name == context_name)
        .cloned()
        .ok_or_else(|| {
            BlockError::message(
                "kubernetes",
                "flatten kubeconfig",
                format!("context `{context_name}` not found"),
            )
        })?;
    let context_value = named_context.context.as_ref().ok_or_else(|| {
        BlockError::message(
            "kubernetes",
            "flatten kubeconfig",
            format!("context `{context_name}` has no body"),
        )
    })?;

    let mut named_cluster = kubeconfig
        .clusters
        .iter()
        .find(|entry| entry.name == context_value.cluster)
        .cloned()
        .ok_or_else(|| {
            BlockError::message(
                "kubernetes",
                "flatten kubeconfig",
                format!("cluster `{}` not found", context_value.cluster),
            )
        })?;
    flatten_cluster(&mut named_cluster)?;

    let named_auth_info = context_value
        .user
        .as_ref()
        .map(|user| {
            kubeconfig
                .auth_infos
                .iter()
                .find(|entry| &entry.name == user)
                .cloned()
                .ok_or_else(|| {
                    BlockError::message(
                        "kubernetes",
                        "flatten kubeconfig",
                        format!("user `{user}` not found"),
                    )
                })
                .and_then(|mut entry| {
                    flatten_auth_info(&mut entry)?;
                    Ok(entry)
                })
        })
        .transpose()?;

    let flattened = Kubeconfig {
        preferences: kubeconfig.preferences,
        clusters: vec![named_cluster],
        auth_infos: named_auth_info.into_iter().collect(),
        contexts: vec![named_context],
        current_context: Some(context_name),
        extensions: kubeconfig.extensions,
        kind: kubeconfig.kind.or(Some("Config".to_string())),
        api_version: kubeconfig.api_version.or(Some("v1".to_string())),
    };

    serde_yml::to_string(&flattened)
        .map_err(|error| BlockError::new("kubernetes", "serialize kubeconfig", error))
}

fn flatten_cluster(named_cluster: &mut NamedCluster) -> Result<(), BlockError> {
    let Some(cluster) = named_cluster.cluster.as_mut() else {
        return Ok(());
    };

    if cluster.certificate_authority_data.is_none()
        && let Some(path) = cluster.certificate_authority.take()
    {
        cluster.certificate_authority_data = Some(read_base64_file(Path::new(&path))?);
    }

    Ok(())
}

fn flatten_auth_info(named_auth_info: &mut NamedAuthInfo) -> Result<(), BlockError> {
    let Some(auth_info) = named_auth_info.auth_info.as_ref() else {
        return Ok(());
    };

    let mut value = serde_json::to_value(auth_info)
        .map_err(|error| BlockError::new("kubernetes", "serialize auth info", error))?;
    let object = value.as_object_mut().ok_or_else(|| {
        BlockError::message(
            "kubernetes",
            "flatten kubeconfig",
            "auth info did not serialize to an object",
        )
    })?;

    inline_string_file(object, "tokenFile", "token", false)?;
    inline_string_file(
        object,
        "client-certificate",
        "client-certificate-data",
        true,
    )?;
    inline_string_file(object, "client-key", "client-key-data", true)?;

    named_auth_info.auth_info = Some(
        serde_json::from_value(value)
            .map_err(|error| BlockError::new("kubernetes", "deserialize auth info", error))?,
    );
    Ok(())
}

fn inline_string_file(
    object: &mut Map<String, Value>,
    path_key: &str,
    data_key: &str,
    base64_encode: bool,
) -> Result<(), BlockError> {
    if object
        .get(data_key)
        .and_then(Value::as_str)
        .is_some_and(|value| !value.is_empty())
    {
        return Ok(());
    }

    let Some(path_value) = object.remove(path_key) else {
        return Ok(());
    };
    let path = path_value.as_str().ok_or_else(|| {
        BlockError::message(
            "kubernetes",
            "flatten kubeconfig",
            format!("{path_key} should be a string"),
        )
    })?;

    let data = if base64_encode {
        read_base64_file(Path::new(path))?
    } else {
        fs::read_to_string(path)
            .map_err(|error| BlockError::new("kubernetes", "read kubeconfig secret", error))?
            .trim()
            .to_string()
    };
    object.insert(data_key.to_string(), Value::String(data));
    Ok(())
}

fn read_base64_file(path: &Path) -> Result<String, BlockError> {
    let bytes = fs::read(path)
        .map_err(|error| BlockError::new("kubernetes", "read kubeconfig file", error))?;
    Ok(STANDARD.encode(bytes))
}
