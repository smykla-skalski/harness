use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io;
use std::net::TcpListener;
use std::os::unix::fs::{DirBuilderExt as _, MetadataExt as _, PermissionsExt as _};
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::{Arc, Mutex};

use fs2::FileExt as _;

const PORT_LEASE_ATTEMPTS: usize = 64;

#[derive(Clone)]
pub struct TcpPortLease {
    inner: Arc<TcpPortLeaseInner>,
}

struct TcpPortLeaseInner {
    port: u16,
    listener: Mutex<Option<TcpListener>>,
    _lock_file: File,
}

impl TcpPortLease {
    pub fn acquire() -> io::Result<Self> {
        let lock_root = user_global_lock_root()?;
        for _ in 0..PORT_LEASE_ATTEMPTS {
            let listener = TcpListener::bind(("127.0.0.1", 0))?;
            let port = listener.local_addr()?.port();
            let lock_path = lock_root.join(format!("tcp-{port}.lock"));
            let lock_file = OpenOptions::new()
                .create(true)
                .read(true)
                .write(true)
                .truncate(false)
                .open(&lock_path)?;

            match lock_file.try_lock_exclusive() {
                Ok(()) => {
                    return Ok(Self {
                        inner: Arc::new(TcpPortLeaseInner {
                            port,
                            listener: Mutex::new(Some(listener)),
                            _lock_file: lock_file,
                        }),
                    });
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::AddrNotAvailable,
            format!(
                "could not reserve a globally unique local port after {PORT_LEASE_ATTEMPTS} attempts"
            ),
        ))
    }

    #[must_use]
    pub fn port(&self) -> u16 {
        self.inner.port
    }

    pub fn output(&self, command: &mut Command) -> io::Result<Output> {
        self.release_listener()?;
        command.output()
    }

    pub(super) fn release_listener(&self) -> io::Result<()> {
        self.inner
            .listener
            .lock()
            .map_err(|_| io::Error::other("TCP port lease listener lock poisoned"))?
            .take();
        Ok(())
    }
}

fn user_global_lock_root() -> io::Result<PathBuf> {
    let uid = uzers::get_current_uid();
    let lock_root = PathBuf::from("/tmp").join(format!("harness-test-port-leases-{uid}"));
    match DirBuilder::new().mode(0o700).create(&lock_root) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }

    let metadata = fs::symlink_metadata(&lock_root)?;
    if !metadata.file_type().is_dir() || metadata.uid() != uid {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "integration port lease root is not a private user-owned directory: {}",
                lock_root.display()
            ),
        ));
    }
    fs::set_permissions(&lock_root, fs::Permissions::from_mode(0o700))?;
    Ok(lock_root)
}
