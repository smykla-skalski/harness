//! Minimal systemd notification protocol support.

#![deny(unsafe_code)]

use std::io;

#[cfg(target_os = "linux")]
const READY_MESSAGE: &[u8] = b"READY=1\n";

/// Failure while notifying systemd that the process is ready.
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum NotifyError {
    #[error("systemd abstract NOTIFY_SOCKET name cannot be empty")]
    EmptyAbstractSocketName,
    #[error("systemd NOTIFY_SOCKET must be an absolute path or abstract name: {socket}")]
    RelativeSocket { socket: String },
    #[error("parse systemd notification socket {socket}: {source}")]
    InvalidAddress { socket: String, source: io::Error },
    #[error("create systemd notification socket: {source}")]
    CreateSocket { source: io::Error },
    #[error("send systemd readiness notification to {socket}: {source}")]
    Send { socket: String, source: io::Error },
    #[error("send systemd readiness notification to {socket}: wrote {sent} of {expected} bytes")]
    IncompleteSend {
        socket: String,
        sent: usize,
        expected: usize,
    },
}

/// Notify systemd that process startup is complete.
///
/// Outside Linux, or when systemd did not configure `NOTIFY_SOCKET`, this is a
/// no-op. Both filesystem-backed and Linux abstract-namespace notification
/// sockets are supported.
///
/// # Errors
/// Returns [`NotifyError`] when a configured Linux notification socket is
/// invalid or cannot receive the readiness datagram.
pub fn notify_ready() -> Result<(), NotifyError> {
    #[cfg(target_os = "linux")]
    {
        notify_ready_linux()
    }

    #[cfg(not(target_os = "linux"))]
    {
        Ok(())
    }
}

#[cfg(target_os = "linux")]
fn notify_ready_linux() -> Result<(), NotifyError> {
    use std::env;
    use std::os::fd::AsRawFd as _;
    use std::os::unix::ffi::OsStrExt as _;

    use nix::sys::socket::{
        AddressFamily, MsgFlags, SockFlag, SockProtocol, SockType, UnixAddr, sendto, socket,
    };

    let Some(notification_socket) = env::var_os("NOTIFY_SOCKET") else {
        return Ok(());
    };
    let socket_label = notification_socket.to_string_lossy().into_owned();
    let socket_bytes = notification_socket.as_os_str().as_bytes();
    let address = if let Some(name) = socket_bytes.strip_prefix(b"@") {
        if name.is_empty() {
            return Err(NotifyError::EmptyAbstractSocketName);
        }
        UnixAddr::new_abstract(name)
    } else {
        if !socket_bytes.starts_with(b"/") {
            return Err(NotifyError::RelativeSocket {
                socket: socket_label,
            });
        }
        UnixAddr::new(notification_socket.as_os_str())
    }
    .map_err(|source| NotifyError::InvalidAddress {
        socket: socket_label.clone(),
        source: source.into(),
    })?;
    let datagram = socket(
        AddressFamily::Unix,
        SockType::Datagram,
        SockFlag::SOCK_CLOEXEC,
        None::<SockProtocol>,
    )
    .map_err(|source| NotifyError::CreateSocket {
        source: source.into(),
    })?;
    let sent = sendto(
        datagram.as_raw_fd(),
        READY_MESSAGE,
        &address,
        MsgFlags::empty(),
    )
    .map_err(|source| NotifyError::Send {
        socket: socket_label.clone(),
        source: source.into(),
    })?;
    if sent != READY_MESSAGE.len() {
        return Err(NotifyError::IncompleteSend {
            socket: socket_label,
            sent,
            expected: READY_MESSAGE.len(),
        });
    }
    Ok(())
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use std::os::fd::AsRawFd as _;
    use std::os::unix::net::UnixDatagram;

    use nix::sys::socket::{
        AddressFamily, MsgFlags, SockFlag, SockProtocol, SockType, UnixAddr, bind, recv, socket,
    };
    use tempfile::tempdir_in;

    use super::{NotifyError, READY_MESSAGE, notify_ready};

    #[test]
    fn notify_ready_is_noop_when_socket_is_unset() {
        temp_env::with_var("NOTIFY_SOCKET", None::<&str>, || {
            notify_ready().expect("unset notification socket should be a no-op");
        });
    }

    #[test]
    fn notify_ready_rejects_empty_abstract_socket_name() {
        let error = temp_env::with_var("NOTIFY_SOCKET", Some("@"), notify_ready)
            .expect_err("empty abstract socket name must fail");

        assert!(matches!(error, NotifyError::EmptyAbstractSocketName));
    }

    #[test]
    fn notify_ready_rejects_relative_socket_path() {
        let error = temp_env::with_var("NOTIFY_SOCKET", Some("notify.sock"), notify_ready)
            .expect_err("relative notification socket path must fail");

        assert!(matches!(error, NotifyError::RelativeSocket { .. }));
    }

    #[test]
    fn notify_ready_sends_ready_datagram_to_filesystem_socket() {
        let temp = tempdir_in("/tmp").expect("short temp dir");
        let socket_path = temp.path().join("notify.sock");
        let receiver = UnixDatagram::bind(&socket_path).expect("bind notification socket");

        temp_env::with_var("NOTIFY_SOCKET", Some(socket_path.as_os_str()), || {
            notify_ready().expect("send readiness notification");
        });

        let mut message = [0_u8; 32];
        let message_len = receiver
            .recv(&mut message)
            .expect("receive readiness datagram");
        assert_eq!(&message[..message_len], READY_MESSAGE);
    }

    #[test]
    fn notify_ready_sends_ready_datagram_to_abstract_socket() {
        let socket_name = format!("harness-notify-test-{}", std::process::id());
        let address = UnixAddr::new_abstract(socket_name.as_bytes()).expect("abstract address");
        let receiver = socket(
            AddressFamily::Unix,
            SockType::Datagram,
            SockFlag::SOCK_CLOEXEC,
            None::<SockProtocol>,
        )
        .expect("create abstract notification socket");
        bind(receiver.as_raw_fd(), &address).expect("bind abstract notification socket");

        temp_env::with_var("NOTIFY_SOCKET", Some(format!("@{socket_name}")), || {
            notify_ready().expect("send abstract readiness notification");
        });

        let mut message = [0_u8; 32];
        let message_len = recv(receiver.as_raw_fd(), &mut message, MsgFlags::empty())
            .expect("receive abstract readiness datagram");
        assert_eq!(&message[..message_len], READY_MESSAGE);
    }

    #[test]
    fn notify_ready_reports_configured_socket_send_failure() {
        let temp = tempdir_in("/tmp").expect("short temp dir");
        let missing = temp.path().join("missing.sock");

        let error = temp_env::with_var("NOTIFY_SOCKET", Some(missing.as_os_str()), notify_ready)
            .expect_err("missing configured socket must fail");

        assert!(matches!(error, NotifyError::Send { .. }));
    }
}
