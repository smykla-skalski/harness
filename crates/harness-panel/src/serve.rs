//! Running the panel.

use std::{
    env,
    ffi::{OsStr, OsString},
    future::pending,
    io,
    net::SocketAddr,
    process,
    time::Duration,
};

#[cfg(target_os = "linux")]
use std::{
    mem::size_of_val,
    net::TcpListener as StdTcpListener,
    os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd},
};

use chrono::Utc;
use tokio::net::TcpListener;
use tokio::signal;
use tokio::time::interval;

use crate::config::PanelConfig;
use crate::error::PanelError;
use crate::http::{PanelState, router};
use crate::store::Store;
use uuid::Uuid;

/// How often expired sessions and unfinished sign-ins are reclaimed. Expiry is
/// enforced on every read, so this only frees rows and can be lazy.
const PRUNE_INTERVAL: Duration = Duration::from_mins(15);
const REQUIRE_SOCKET_ACTIVATION: &str = "HARNESS_PANEL_REQUIRE_SOCKET_ACTIVATION";
const LISTEN_PID: &str = "LISTEN_PID";
const LISTEN_FDS: &str = "LISTEN_FDS";
const LISTEN_FDNAMES: &str = "LISTEN_FDNAMES";
pub(crate) const SYSTEMD_SOCKET_NAME: &str = "harness-panel-http";
#[cfg(target_os = "linux")]
const SYSTEMD_LISTEN_FD: RawFd = 3;

#[derive(Debug, Default)]
struct ActivationEnvironment {
    required: Option<OsString>,
    listen_pid: Option<OsString>,
    listen_fds: Option<OsString>,
    listen_fdnames: Option<OsString>,
}

impl ActivationEnvironment {
    fn read() -> Self {
        Self {
            required: env::var_os(REQUIRE_SOCKET_ACTIVATION),
            listen_pid: env::var_os(LISTEN_PID),
            listen_fds: env::var_os(LISTEN_FDS),
            listen_fdnames: env::var_os(LISTEN_FDNAMES),
        }
    }

    fn requires_listener(&self, current_pid: u32) -> Result<bool, PanelError> {
        match self.required.as_deref() {
            None => Ok(false),
            Some(value) if value == OsStr::new("0") => Ok(false),
            Some(value) if value == OsStr::new("1") => {
                self.validate_socket_protocol(current_pid)?;
                Ok(true)
            }
            Some(_) => Err(activation_error(format!(
                "{REQUIRE_SOCKET_ACTIVATION} must be 0 or 1"
            ))),
        }
    }

    fn validate_socket_protocol(&self, current_pid: u32) -> Result<(), PanelError> {
        let listen_pid = activation_number(LISTEN_PID, self.listen_pid.as_deref())?;
        if listen_pid != current_pid {
            return Err(activation_error(format!(
                "{LISTEN_PID} names process {listen_pid}, not {current_pid}"
            )));
        }

        let listen_fds = activation_number(LISTEN_FDS, self.listen_fds.as_deref())?;
        if listen_fds != 1 {
            return Err(activation_error(format!(
                "{LISTEN_FDS} must describe exactly one descriptor, got {listen_fds}"
            )));
        }
        match self.listen_fdnames.as_deref() {
            Some(name) if name == OsStr::new(SYSTEMD_SOCKET_NAME) => Ok(()),
            Some(_) => Err(activation_error(format!(
                "{LISTEN_FDNAMES} must be exactly {SYSTEMD_SOCKET_NAME}"
            ))),
            None => Err(activation_error(format!("{LISTEN_FDNAMES} is missing"))),
        }
    }
}

fn activation_number(name: &str, value: Option<&OsStr>) -> Result<u32, PanelError> {
    let value = value
        .and_then(OsStr::to_str)
        .ok_or_else(|| activation_error(format!("{name} is missing or is not valid UTF-8")))?;
    value
        .parse()
        .map_err(|_| activation_error(format!("{name} is not an unsigned decimal integer")))
}

fn activation_error(message: impl Into<String>) -> PanelError {
    PanelError::config(format!("systemd socket activation: {}", message.into()))
}

async fn open_listener(listen: SocketAddr) -> Result<TcpListener, PanelError> {
    if ActivationEnvironment::read().requires_listener(process::id())? {
        #[cfg(target_os = "linux")]
        {
            let listener = adopt_systemd_listener(SYSTEMD_LISTEN_FD, listen)?;
            return TcpListener::from_std(listener).map_err(|source| PanelError::Bind {
                address: listen.to_string(),
                source,
            });
        }

        #[cfg(not(target_os = "linux"))]
        return Err(activation_error(
            "descriptor adoption is only supported on Linux",
        ));
    }

    TcpListener::bind(listen)
        .await
        .map_err(|source| PanelError::Bind {
            address: listen.to_string(),
            source,
        })
}

#[cfg(target_os = "linux")]
fn adopt_systemd_listener(fd: RawFd, expected: SocketAddr) -> Result<StdTcpListener, PanelError> {
    let descriptor = duplicate_descriptor(fd).map_err(|source| {
        activation_error(format!("cannot duplicate descriptor {fd}: {source}"))
    })?;
    let socket_type = socket_option(descriptor.as_fd(), libc::SO_TYPE).map_err(|source| {
        activation_error(format!("cannot inspect descriptor {fd} type: {source}"))
    })?;
    if socket_type != libc::SOCK_STREAM {
        return Err(activation_error(format!(
            "descriptor {fd} is not a TCP stream socket"
        )));
    }
    let accepting = socket_option(descriptor.as_fd(), libc::SO_ACCEPTCONN).map_err(|source| {
        activation_error(format!("cannot inspect descriptor {fd} state: {source}"))
    })?;
    if accepting != 1 {
        return Err(activation_error(format!(
            "descriptor {fd} is not a listening socket"
        )));
    }

    let listener = StdTcpListener::from(descriptor);
    let actual = listener.local_addr().map_err(|source| {
        activation_error(format!("cannot inspect descriptor {fd} address: {source}"))
    })?;
    if actual != expected {
        return Err(activation_error(format!(
            "descriptor {fd} is bound to {actual}, expected {expected}"
        )));
    }
    listener.set_nonblocking(true).map_err(|source| {
        activation_error(format!("cannot make descriptor {fd} nonblocking: {source}"))
    })?;
    Ok(listener)
}

#[cfg(target_os = "linux")]
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

/// Open the store, bind the listener, and serve until shutdown.
///
/// # Errors
/// Returns [`PanelError`] when the store cannot be opened, the address cannot
/// be bound, or the server stops with an error.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub async fn run(config: PanelConfig) -> Result<(), PanelError> {
    let store = Store::open(&config.state_dir).await?;
    let listen = config.listen;
    let state = PanelState::new(config, store.clone())?;
    pair_with_daemon(&state).await?;

    if state.assets.is_placeholder() {
        tracing::warn!(
            "this binary was built without the panel's web assets and will serve a placeholder page"
        );
    }

    let listener = open_listener(listen).await?;
    let bound = listener.local_addr().map_err(|source| PanelError::Bind {
        address: listen.to_string(),
        source,
    })?;
    tracing::info!(
        address = %bound,
        base_path = %state.config.base_path,
        public_origin = %state.config.public_origin,
        "panel listening"
    );

    tokio::spawn(prune_loop(store));

    axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|source| PanelError::Bind {
            address: bound.to_string(),
            source,
        })
}

/// Claim the daemon credential the panel runs as, if it needs one.
///
/// A code supplied on the command line always wins: it is how an operator
/// recovers from a credential the daemon has revoked. Without one, an existing
/// credential is kept and a panel that has neither says so now rather than on
/// the first person's attempt to generate a link.
///
/// # Errors
/// Returns [`PanelError::Daemon`] when the daemon refuses the code, and
/// [`PanelError::Storage`] when the credential cannot be stored.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn pair_with_daemon(state: &PanelState) -> Result<(), PanelError> {
    if let Some(code) = state.daemon.config.pair_code.as_deref() {
        let client_id = Uuid::new_v4().to_string();
        let credential = state.daemon.client.claim(code, &client_id).await?;
        tracing::info!(
            client_id = %credential.client_id,
            role = %credential.role,
            "panel claimed a daemon credential"
        );
        state
            .store
            .store_daemon_credential(&credential, Utc::now())
            .await?;
        return Ok(());
    }

    if state.store.daemon_credential().await?.is_none() {
        tracing::warn!(
            "the panel has no daemon credential; pass --daemon-pair-code once to claim one, or \
             nobody will be able to generate a pairing link"
        );
    }
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn prune_loop(store: Store) {
    let mut ticker = interval(PRUNE_INTERVAL);
    // The first tick fires immediately, which clears whatever a previous run
    // left behind before the panel starts adding to it.
    loop {
        ticker.tick().await;
        match store.prune_expired(Utc::now()).await {
            Ok(0) => {}
            Ok(removed) => tracing::debug!(removed, "pruned expired panel rows"),
            Err(error) => tracing::warn!(%error, "pruning expired panel rows failed"),
        }
    }
}

/// Stop on the signals systemd sends, so a restart is not a kill.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn shutdown_signal() {
    let interrupt = async {
        wait_for_interrupt(signal::ctrl_c().await).await;
    };

    #[cfg(unix)]
    let terminate = wait_for_terminate(signal::unix::signal(signal::unix::SignalKind::terminate()));

    #[cfg(not(unix))]
    let terminate = pending::<()>();

    tokio::select! {
        () = interrupt => {}
        () = terminate => {}
    }
    tracing::info!("panel shutting down");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn wait_for_interrupt(result: io::Result<()>) {
    if let Err(error) = result {
        tracing::warn!(%error, "cannot listen for Ctrl-C");
        pending::<()>().await;
    }
}

#[cfg(unix)]
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn wait_for_terminate(result: io::Result<signal::unix::Signal>) {
    let mut stream = match result {
        Ok(stream) => stream,
        Err(error) => {
            tracing::warn!(%error, "cannot listen for SIGTERM");
            pending::<signal::unix::Signal>().await
        }
    };
    stream.recv().await;
}

#[cfg(test)]
mod tests {
    use std::{ffi::OsString, io};

    #[cfg(target_os = "linux")]
    use std::{
        net::{TcpListener as StdTcpListener, TcpStream, UdpSocket},
        os::fd::AsRawFd,
    };

    #[cfg(target_os = "linux")]
    use super::adopt_systemd_listener;
    #[cfg(unix)]
    use super::wait_for_terminate;
    use super::{ActivationEnvironment, wait_for_interrupt};
    use tokio::time::{Duration, timeout};

    fn activation_environment(
        required: Option<&str>,
        listen_pid: Option<&str>,
        listen_fds: Option<&str>,
    ) -> ActivationEnvironment {
        ActivationEnvironment {
            required: required.map(OsString::from),
            listen_pid: listen_pid.map(OsString::from),
            listen_fds: listen_fds.map(OsString::from),
            listen_fdnames: Some(OsString::from(super::SYSTEMD_SOCKET_NAME)),
        }
    }

    #[test]
    fn socket_activation_is_opt_in() {
        for required in [None, Some("0")] {
            let environment = activation_environment(required, Some("wrong"), Some("wrong"));

            assert!(!environment.requires_listener(42).expect("manual bind"));
        }
    }

    #[test]
    fn required_socket_activation_accepts_one_descriptor_for_this_process() {
        let environment = activation_environment(Some("1"), Some("42"), Some("1"));

        assert!(
            environment
                .requires_listener(42)
                .expect("socket activation")
        );
    }

    #[test]
    fn required_socket_activation_rejects_invalid_protocol_state() {
        for (listen_pid, listen_fds, expected) in [
            (None, Some("1"), "LISTEN_PID is missing"),
            (Some("not-a-pid"), Some("1"), "LISTEN_PID is not"),
            (Some("41"), Some("1"), "names process 41, not 42"),
            (Some("42"), None, "LISTEN_FDS is missing"),
            (Some("42"), Some("many"), "LISTEN_FDS is not"),
            (Some("42"), Some("0"), "exactly one descriptor"),
            (Some("42"), Some("2"), "exactly one descriptor"),
        ] {
            let environment = activation_environment(Some("1"), listen_pid, listen_fds);

            let error = environment
                .requires_listener(42)
                .expect_err("invalid activation must fail");

            assert!(error.to_string().contains(expected), "{error}");
        }
    }

    #[test]
    fn required_socket_activation_rejects_a_missing_or_wrong_descriptor_name() {
        for listen_fdnames in [None, Some("panel"), Some("harness-panel-http:extra")] {
            let mut environment = activation_environment(Some("1"), Some("42"), Some("1"));
            environment.listen_fdnames = listen_fdnames.map(OsString::from);

            let error = environment
                .requires_listener(42)
                .expect_err("wrong descriptor name must fail");

            assert!(error.to_string().contains("LISTEN_FDNAMES"), "{error}");
        }
    }

    #[test]
    fn an_invalid_activation_requirement_does_not_fall_back_to_binding() {
        let environment = activation_environment(Some("yes"), Some("42"), Some("1"));

        let error = environment
            .requires_listener(42)
            .expect_err("invalid requirement must fail");

        assert!(error.to_string().contains("must be 0 or 1"), "{error}");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_listening_tcp_socket_is_duplicated_and_made_nonblocking() {
        let source = StdTcpListener::bind("127.0.0.1:0").expect("bind");
        let expected = source.local_addr().expect("local address");

        let adopted = adopt_systemd_listener(source.as_raw_fd(), expected).expect("adopt listener");
        drop(source);

        assert_eq!(adopted.local_addr().expect("adopted address"), expected);
        let error = adopted.accept().expect_err("listener must be nonblocking");
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn socket_activation_rejects_the_wrong_bound_address() {
        let source = StdTcpListener::bind("127.0.0.1:0").expect("bind source");
        let expected = StdTcpListener::bind("127.0.0.1:0").expect("bind expected");
        let expected = expected.local_addr().expect("expected address");

        let error = adopt_systemd_listener(source.as_raw_fd(), expected)
            .expect_err("wrong address must fail");

        assert!(error.to_string().contains("is bound to"), "{error}");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn socket_activation_rejects_a_datagram_socket() {
        let socket = UdpSocket::bind("127.0.0.1:0").expect("bind datagram");
        let expected = socket.local_addr().expect("datagram address");

        let error =
            adopt_systemd_listener(socket.as_raw_fd(), expected).expect_err("datagram must fail");

        assert!(error.to_string().contains("not a TCP stream"), "{error}");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn socket_activation_rejects_a_non_listening_stream_socket() {
        let listener = StdTcpListener::bind("127.0.0.1:0").expect("bind listener");
        let stream =
            TcpStream::connect(listener.local_addr().expect("listener address")).expect("connect");
        let expected = stream.local_addr().expect("stream address");

        let error = adopt_systemd_listener(stream.as_raw_fd(), expected)
            .expect_err("connected stream must fail");

        assert!(
            error.to_string().contains("not a listening socket"),
            "{error}"
        );
    }

    #[tokio::test]
    async fn failed_interrupt_registration_does_not_request_shutdown() {
        let waiting = wait_for_interrupt(Err(io::Error::other("cannot register")));

        assert!(timeout(Duration::from_millis(10), waiting).await.is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn failed_terminate_registration_does_not_request_shutdown() {
        let waiting = wait_for_terminate(Err(io::Error::other("cannot register")));

        assert!(timeout(Duration::from_millis(10), waiting).await.is_err());
    }
}
