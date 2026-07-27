//! Runtime proof that the managed companion socket owns the proxy target.

use std::env;
use std::ffi::{OsStr, OsString};
use std::net::IpAddr;
#[cfg(any(target_os = "linux", test))]
use std::net::SocketAddr;
use std::process;

use axum::http::{Uri, uri::Authority};
#[cfg(target_os = "linux")]
use std::io;
#[cfg(target_os = "linux")]
use std::mem::size_of_val;
#[cfg(target_os = "linux")]
use std::net::TcpListener;
#[cfg(target_os = "linux")]
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};

use harness_kernel::errors::{CliError, CliErrorKind};

const LISTEN_PID: &str = "LISTEN_PID";
const LISTEN_FDS: &str = "LISTEN_FDS";
const LISTEN_FDNAMES: &str = "LISTEN_FDNAMES";
const PANEL_SOCKET_FD_NAME: &str = "harness-panel-http";
#[cfg(target_os = "linux")]
const SYSTEMD_LISTEN_FD: RawFd = 3;

#[derive(Debug, Default)]
struct ActivationEnvironment {
    pid: Option<OsString>,
    fds: Option<OsString>,
    fd_names: Option<OsString>,
}

impl ActivationEnvironment {
    fn read() -> Self {
        Self {
            pid: env::var_os(LISTEN_PID),
            fds: env::var_os(LISTEN_FDS),
            fd_names: env::var_os(LISTEN_FDNAMES),
        }
    }

    fn validate(&self, current_pid: u32) -> Result<(), CliError> {
        let listen_pid = activation_number(LISTEN_PID, self.pid.as_deref())?;
        if listen_pid != current_pid {
            return Err(activation_error(format!(
                "{LISTEN_PID} names process {listen_pid}, not {current_pid}"
            )));
        }
        let listen_fds = activation_number(LISTEN_FDS, self.fds.as_deref())?;
        if listen_fds != 1 {
            return Err(activation_error(format!(
                "{LISTEN_FDS} must describe exactly one descriptor, got {listen_fds}"
            )));
        }
        match self.fd_names.as_deref() {
            Some(name) if name == OsStr::new(PANEL_SOCKET_FD_NAME) => Ok(()),
            Some(_) => Err(activation_error(format!(
                "{LISTEN_FDNAMES} must be exactly {PANEL_SOCKET_FD_NAME}"
            ))),
            None => Err(activation_error(format!("{LISTEN_FDNAMES} is missing"))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ExpectedHost {
    Exact(IpAddr),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ExpectedListener {
    host: ExpectedHost,
    port: u16,
}

impl ExpectedListener {
    fn from_upstream(upstream: &str) -> Result<Self, CliError> {
        let parsed = upstream
            .parse::<Uri>()
            .map_err(|_| activation_error("companion upstream is not a valid URL"))?;
        if !parsed
            .scheme_str()
            .is_some_and(|scheme| scheme.eq_ignore_ascii_case("http"))
        {
            return Err(activation_error("companion upstream must use http"));
        }
        let authority = parsed
            .authority()
            .ok_or_else(|| activation_error("companion upstream has no host"))?;
        let host_text = authority
            .host()
            .trim_start_matches('[')
            .trim_end_matches(']');
        let host = if let Ok(address) = host_text.parse::<IpAddr>() {
            ExpectedHost::Exact(address)
        } else {
            return Err(activation_error(
                "companion upstream host is not a numeric loopback literal",
            ));
        };
        let port = validated_port(authority)?;
        Ok(Self { host, port })
    }

    // Socket activation is a systemd concept, so the only caller outside the
    // tests is Linux-only. Without this the lib is dead-code-clean under
    // cfg(test) but not as a plain dependency, which is exactly how the
    // integration targets build it: `mise run test:integration` stopped
    // compiling on macOS.
    #[cfg(any(target_os = "linux", test))]
    fn matches(self, actual: SocketAddr) -> bool {
        self.port == actual.port()
            && match self.host {
                ExpectedHost::Exact(expected) => expected == actual.ip(),
            }
    }
}

fn validated_port(authority: &Authority) -> Result<u16, CliError> {
    let suffix = authority
        .as_str()
        .strip_prefix(authority.host())
        .ok_or_else(|| activation_error("companion upstream authority contains user information"))?;
    if suffix.is_empty() {
        return Ok(80);
    }
    let port = suffix
        .strip_prefix(':')
        .and_then(|value| value.parse::<u16>().ok())
        .filter(|port| *port != 0)
        .ok_or_else(|| activation_error("companion upstream has an invalid explicit port"))?;
    Ok(port)
}

pub(super) fn validate_companion_socket_activation(
    upstream: Option<&str>,
    activated: bool,
) -> Result<(), CliError> {
    if !activated {
        return Ok(());
    }
    let upstream =
        upstream.ok_or_else(|| activation_error("socket activation has no companion upstream"))?;
    let expected = ExpectedListener::from_upstream(upstream)?;
    ActivationEnvironment::read().validate(process::id())?;

    #[cfg(target_os = "linux")]
    return validate_systemd_listener(SYSTEMD_LISTEN_FD, expected);

    #[cfg(not(target_os = "linux"))]
    let _ = expected;
    #[cfg(not(target_os = "linux"))]
    Err(activation_error(
        "companion socket activation is supported only on Linux",
    ))
}

fn activation_number(name: &str, value: Option<&OsStr>) -> Result<u32, CliError> {
    let value = value
        .and_then(OsStr::to_str)
        .ok_or_else(|| activation_error(format!("{name} is missing or is not valid UTF-8")))?;
    value
        .parse()
        .map_err(|_| activation_error(format!("{name} is not an unsigned decimal integer")))
}

fn activation_error(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_parse(format!(
        "companion systemd socket activation: {}",
        message.into()
    ))
    .into()
}

#[cfg(target_os = "linux")]
fn validate_systemd_listener(fd: RawFd, expected: ExpectedListener) -> Result<(), CliError> {
    let descriptor = duplicate_descriptor(fd)
        .map_err(|error| activation_error(format!("cannot duplicate descriptor {fd}: {error}")))?;
    let socket_type = socket_option(descriptor.as_fd(), libc::SO_TYPE)
        .map_err(|error| activation_error(format!("cannot inspect descriptor {fd}: {error}")))?;
    let socket_protocol = socket_option(descriptor.as_fd(), libc::SO_PROTOCOL)
        .map_err(|error| activation_error(format!("cannot inspect descriptor {fd}: {error}")))?;
    if !is_tcp_stream(socket_type, socket_protocol) {
        return Err(activation_error(format!(
            "descriptor {fd} is not a TCP stream socket"
        )));
    }
    let accepting = socket_option(descriptor.as_fd(), libc::SO_ACCEPTCONN)
        .map_err(|error| activation_error(format!("cannot inspect descriptor {fd}: {error}")))?;
    if accepting != 1 {
        return Err(activation_error(format!(
            "descriptor {fd} is not a listening socket"
        )));
    }

    let listener = TcpListener::from(descriptor);
    let actual = listener.local_addr().map_err(|error| {
        activation_error(format!("cannot inspect descriptor {fd} address: {error}"))
    })?;
    if !expected.matches(actual) {
        return Err(activation_error(format!(
            "descriptor {fd} is bound to {actual}, not the companion upstream"
        )));
    }
    mark_close_on_exec(fd).map_err(|error| {
        activation_error(format!(
            "cannot keep descriptor {fd} out of child processes: {error}"
        ))
    })?;
    Ok(())
}

#[cfg(target_os = "linux")]
fn is_tcp_stream(socket_type: libc::c_int, socket_protocol: libc::c_int) -> bool {
    socket_type == libc::SOCK_STREAM && socket_protocol == libc::IPPROTO_TCP
}

#[cfg(target_os = "linux")]
#[allow(unsafe_code)]
fn duplicate_descriptor(fd: RawFd) -> io::Result<OwnedFd> {
    // SAFETY: fcntl only observes `fd`. On success it returns a new descriptor
    // whose ownership has not been handed to any other Rust value.
    let duplicated = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
    if duplicated == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the successful F_DUPFD_CLOEXEC call returned a newly owned fd.
    Ok(unsafe { OwnedFd::from_raw_fd(duplicated) })
}

#[cfg(target_os = "linux")]
#[allow(unsafe_code)]
fn socket_option(fd: BorrowedFd<'_>, option: libc::c_int) -> io::Result<libc::c_int> {
    let mut value = 0;
    let mut length = size_of_val(&value)
        .try_into()
        .expect("c_int size fits socklen_t");
    // SAFETY: both output pointers are valid for their declared lengths, and
    // `fd` stays borrowed for the duration of the call.
    let result = unsafe {
        libc::getsockopt(
            fd.as_raw_fd(),
            libc::SOL_SOCKET,
            option,
            (&raw mut value).cast(),
            &raw mut length,
        )
    };
    if result == -1 {
        return Err(io::Error::last_os_error());
    }
    if usize::try_from(length).ok() != Some(size_of_val(&value)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "socket option returned an unexpected size",
        ));
    }
    Ok(value)
}

#[cfg(target_os = "linux")]
fn mark_close_on_exec(fd: RawFd) -> io::Result<()> {
    let flags = descriptor_flags(fd)?;
    set_descriptor_flags(fd, flags | libc::FD_CLOEXEC)
}

#[cfg(target_os = "linux")]
#[allow(unsafe_code)]
fn descriptor_flags(fd: RawFd) -> io::Result<libc::c_int> {
    // SAFETY: F_GETFD only reads descriptor metadata and does not take pointers.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(flags)
}

#[cfg(target_os = "linux")]
#[allow(unsafe_code)]
fn set_descriptor_flags(fd: RawFd, flags: libc::c_int) -> io::Result<()> {
    // SAFETY: F_SETFD updates only this descriptor's flags.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, flags) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use super::{ActivationEnvironment, ExpectedListener};

    fn environment(pid: &str, fds: &str, names: Option<&str>) -> ActivationEnvironment {
        ActivationEnvironment {
            pid: Some(OsString::from(pid)),
            fds: Some(OsString::from(fds)),
            fd_names: names.map(OsString::from),
        }
    }

    #[test]
    fn activation_requires_one_named_descriptor_for_this_process() {
        environment("42", "1", Some("harness-panel-http"))
            .validate(42)
            .expect("valid activation");

        for invalid in [
            environment("41", "1", Some("harness-panel-http")),
            environment("42", "2", Some("harness-panel-http")),
            environment("42", "1", Some("another-socket")),
            environment("42", "1", None),
        ] {
            assert!(invalid.validate(42).is_err());
        }
    }

    #[test]
    fn the_inherited_address_must_match_the_proxy_upstream() {
        let exact =
            ExpectedListener::from_upstream("http://127.0.0.1:8787").expect("exact listener");
        assert!(exact.matches("127.0.0.1:8787".parse().expect("exact address")));
        assert!(!exact.matches("127.0.0.1:8788".parse().expect("wrong port")));
        assert!(!exact.matches("[::1]:8787".parse().expect("wrong family")));
        assert!(ExpectedListener::from_upstream("http://localhost:8787").is_err());
    }

    #[test]
    fn malformed_explicit_ports_are_never_treated_as_the_default_port() {
        for upstream in [
            "http://127.0.0.1:",
            "http://127.0.0.1:not-a-port",
            "http://127.0.0.1:0",
            "http://127.0.0.1:65536",
            "http://[::1]:",
            "http://[::1]:not-a-port",
            "http://[::1]:0",
            "http://[::1]:65536",
        ] {
            ExpectedListener::from_upstream(upstream)
                .expect_err(&format!("{upstream} must have a valid nonzero port"));
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_real_listener_is_checked_by_address_and_protocol() {
        use std::net::{TcpListener, UdpSocket};
        use std::os::fd::AsRawFd as _;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind listener");
        let actual = listener.local_addr().expect("listener address");
        let expected = ExpectedListener::from_upstream(&format!("http://{actual}"))
            .expect("expected listener");
        let flags = super::descriptor_flags(listener.as_raw_fd()).expect("descriptor flags");
        super::set_descriptor_flags(listener.as_raw_fd(), flags & !libc::FD_CLOEXEC)
            .expect("clear close-on-exec");

        super::validate_systemd_listener(listener.as_raw_fd(), expected)
            .expect("matching listener");
        assert_ne!(
            super::descriptor_flags(listener.as_raw_fd()).expect("descriptor flags")
                & libc::FD_CLOEXEC,
            0,
            "the inherited listener must not leak through later execs"
        );

        let wrong = ExpectedListener::from_upstream("http://127.0.0.1:1").expect("wrong listener");
        assert!(super::validate_systemd_listener(listener.as_raw_fd(), wrong).is_err());

        let datagram = UdpSocket::bind("127.0.0.1:0").expect("bind datagram");
        let datagram_address = ExpectedListener::from_upstream(&format!(
            "http://{}",
            datagram.local_addr().expect("datagram address")
        ))
        .expect("datagram address");
        assert!(super::validate_systemd_listener(datagram.as_raw_fd(), datagram_address).is_err());
        assert!(!super::is_tcp_stream(libc::SOCK_STREAM, libc::IPPROTO_UDP));
    }
}
