use std::path::Path;
use std::sync::OnceLock;

use kube::Client;
use kube::config::{Config, KubeConfigOptions, Kubeconfig};
use rustls::crypto::ring::default_provider;

use crate::infra::blocks::BlockError;
use crate::infra::exec::RUNTIME;

pub(super) struct ClientBundle {
    pub(super) client: Client,
    pub(super) default_namespace: String,
    pub(super) cluster_server: String,
}

static RUSTLS_PROVIDER: OnceLock<()> = OnceLock::new();

pub(super) fn client_bundle(kubeconfig: Option<&Path>) -> Result<ClientBundle, BlockError> {
    ensure_rustls_provider();
    let config = if let Some(path) = kubeconfig {
        let kubeconfig = Kubeconfig::read_from(path)
            .map_err(|error| BlockError::new("kubernetes", "read kubeconfig", error))?;
        RUNTIME
            .block_on(Config::from_custom_kubeconfig(
                kubeconfig,
                &KubeConfigOptions::default(),
            ))
            .map_err(|error| BlockError::new("kubernetes", "load kubeconfig", error))?
    } else {
        RUNTIME
            .block_on(Config::infer())
            .map_err(|error| BlockError::new("kubernetes", "infer kubeconfig", error))?
    };

    let cluster_server = config.cluster_url.to_string();
    let default_namespace = config.default_namespace.clone();
    let client = RUNTIME
        .block_on(async move { Client::try_from(config) })
        .map_err(|error| BlockError::new("kubernetes", "build client", error))?;

    Ok(ClientBundle {
        client,
        default_namespace,
        cluster_server,
    })
}

fn ensure_rustls_provider() {
    RUSTLS_PROVIDER.get_or_init(|| {
        let _ = default_provider().install_default();
    });
}
