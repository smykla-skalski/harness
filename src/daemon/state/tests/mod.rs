mod audit;
mod locks;
mod manifest;
mod paths;

use std::sync::Arc;

use super::{
    DaemonBinaryStamp, DaemonManifest, HostBridgeManifest, auth_token_path,
    set_daemon_root_override, set_manifest_write_hook,
};

pub(super) struct ManifestWriteHookReset;

impl Drop for ManifestWriteHookReset {
    fn drop(&mut self) {
        set_manifest_write_hook(None);
    }
}

pub(super) fn install_manifest_write_hook<F>(hook: F) -> ManifestWriteHookReset
where
    F: Fn() + Send + Sync + 'static,
{
    set_manifest_write_hook(Some(Arc::new(hook)));
    ManifestWriteHookReset
}

pub(super) fn reset_override_for_tests() {
    set_daemon_root_override(None);
}

pub(super) fn sample_manifest(pid: u32, endpoint: &str) -> DaemonManifest {
    DaemonManifest {
        version: env!("CARGO_PKG_VERSION").into(),
        pid,
        endpoint: endpoint.into(),
        started_at: "2026-04-11T00:00:00Z".into(),
        token_path: auth_token_path().display().to_string(),
        sandboxed: false,
        host_bridge: HostBridgeManifest::default(),
        revision: 0,
        updated_at: String::new(),
        binary_stamp: Some(DaemonBinaryStamp {
            helper_path: "/tmp/harness-helper".into(),
            device_identifier: 1,
            inode: 2,
            file_size: 3,
            modification_time_interval_since_1970: 4.0,
        }),
    }
}
