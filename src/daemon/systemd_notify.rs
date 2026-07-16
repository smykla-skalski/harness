use crate::errors::CliError;

#[cfg(target_os = "linux")]
const READY_MESSAGE: &[u8] = b"READY=1\n";

/// Notify systemd that daemon HTTP startup is complete.
///
/// Outside Linux, or when systemd did not configure `NOTIFY_SOCKET`, this is a
/// no-op. Both filesystem-backed and Linux abstract-namespace notification
/// sockets are supported.
///
/// # Errors
/// Returns [`CliError`] when a configured Linux notification socket is invalid
/// or cannot receive the readiness datagram.
pub(crate) fn notify_ready() -> Result<(), CliError> {
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
fn notify_ready_linux() -> Result<(), CliError> {
    use std::env;
    use std::os::fd::AsRawFd as _;
    use std::os::unix::ffi::OsStrExt as _;

    use nix::sys::socket::{
        AddressFamily, MsgFlags, SockFlag, SockProtocol, SockType, UnixAddr, sendto, socket,
    };

    use crate::errors::CliErrorKind;

    let Some(notification_socket) = env::var_os("NOTIFY_SOCKET") else {
        return Ok(());
    };
    let socket_bytes = notification_socket.as_os_str().as_bytes();
    let address = if let Some(name) = socket_bytes.strip_prefix(b"@") {
        if name.is_empty() {
            return Err(CliErrorKind::workflow_io(
                "systemd abstract NOTIFY_SOCKET name cannot be empty".to_string(),
            )
            .into());
        }
        UnixAddr::new_abstract(name)
    } else {
        if !socket_bytes.starts_with(b"/") {
            return Err(CliErrorKind::workflow_io(format!(
                "systemd NOTIFY_SOCKET must be an absolute path or abstract name: {}",
                notification_socket.to_string_lossy()
            ))
            .into());
        }
        UnixAddr::new(notification_socket.as_os_str())
    }
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "parse systemd notification socket {}: {error}",
            notification_socket.to_string_lossy()
        )))
    })?;
    let datagram = socket(
        AddressFamily::Unix,
        SockType::Datagram,
        SockFlag::SOCK_CLOEXEC,
        None::<SockProtocol>,
    )
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "create systemd notification socket: {error}"
        )))
    })?;
    let sent = sendto(
        datagram.as_raw_fd(),
        READY_MESSAGE,
        &address,
        MsgFlags::empty(),
    )
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "send systemd readiness notification to {}: {error}",
            notification_socket.to_string_lossy()
        )))
    })?;
    if sent != READY_MESSAGE.len() {
        return Err(CliErrorKind::workflow_io(format!(
            "send systemd readiness notification to {}: wrote {sent} of {} bytes",
            notification_socket.to_string_lossy(),
            READY_MESSAGE.len()
        ))
        .into());
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

    use super::{READY_MESSAGE, notify_ready};

    #[test]
    fn notify_ready_is_noop_when_socket_is_unset() {
        temp_env::with_var("NOTIFY_SOCKET", None::<&str>, || {
            notify_ready().expect("unset notification socket should be a no-op");
        });
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
        let received = receiver
            .recv(&mut message)
            .expect("receive readiness datagram");
        assert_eq!(&message[..received], READY_MESSAGE);
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
        let received = recv(receiver.as_raw_fd(), &mut message, MsgFlags::empty())
            .expect("receive abstract readiness datagram");
        assert_eq!(&message[..received], READY_MESSAGE);
    }

    #[test]
    fn notify_ready_reports_configured_socket_send_failure() {
        let temp = tempdir_in("/tmp").expect("short temp dir");
        let missing = temp.path().join("missing.sock");

        let error = temp_env::with_var("NOTIFY_SOCKET", Some(missing.as_os_str()), notify_ready)
            .expect_err("missing configured socket must fail");

        assert!(
            error
                .to_string()
                .contains("send systemd readiness notification")
        );
    }
}
