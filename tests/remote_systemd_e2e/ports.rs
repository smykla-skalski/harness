use std::fs::{self, DirBuilder, File, OpenOptions};
use std::net::{SocketAddr, TcpStream};
use std::os::unix::fs::{DirBuilderExt as _, MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::time::Duration;

use fs2::FileExt as _;

pub struct LowPortPairLease {
    https_port: u16,
    http_port: u16,
    _https_lock: File,
    _http_lock: File,
}

impl LowPortPairLease {
    pub fn acquire() -> Result<Self, String> {
        let root = port_lock_root()?;
        for (https_port, http_port) in [(944, 908), (943, 907), (942, 906), (941, 905)] {
            if tcp_port_accepts(https_port) || tcp_port_accepts(http_port) {
                continue;
            }
            let Some(https_lock) = try_lock_port(&root, https_port)? else {
                continue;
            };
            let Some(http_lock) = try_lock_port(&root, http_port)? else {
                continue;
            };
            if tcp_port_accepts(https_port) || tcp_port_accepts(http_port) {
                continue;
            }
            return Ok(Self {
                https_port,
                http_port,
                _https_lock: https_lock,
                _http_lock: http_lock,
            });
        }
        Err("no free low-port pair available for systemd e2e".to_string())
    }

    pub const fn https_port(&self) -> u16 {
        self.https_port
    }

    pub const fn http_port(&self) -> u16 {
        self.http_port
    }
}

fn try_lock_port(root: &Path, port: u16) -> Result<Option<File>, String> {
    let path = root.join(format!("tcp-{port}.lock"));
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&path)
        .map_err(|error| format!("open port lease {}: {error}", path.display()))?;
    match file.try_lock_exclusive() {
        Ok(()) => Ok(Some(file)),
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => Ok(None),
        Err(error) => Err(format!("lock port lease {}: {error}", path.display())),
    }
}

fn port_lock_root() -> Result<PathBuf, String> {
    let uid = uzers::get_current_uid();
    let root = PathBuf::from("/tmp").join(format!("harness-test-port-leases-{uid}"));
    match DirBuilder::new().mode(0o700).create(&root) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => {
            return Err(format!(
                "create port lease root {}: {error}",
                root.display()
            ));
        }
    }
    let metadata = fs::symlink_metadata(&root)
        .map_err(|error| format!("inspect port lease root {}: {error}", root.display()))?;
    if !metadata.file_type().is_dir() || metadata.uid() != uid {
        return Err(format!(
            "port lease root must be an owned directory: {}",
            root.display()
        ));
    }
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("secure port lease root {}: {error}", root.display()))?;
    Ok(root)
}

fn tcp_port_accepts(port: u16) -> bool {
    TcpStream::connect_timeout(
        &SocketAddr::from(([127, 0, 0, 1], port)),
        Duration::from_millis(100),
    )
    .is_ok()
}
