use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;
use axum::extract::connect_info::Connected;
use axum::serve::{IncomingStream, Listener};
use rustls::ServerConfig;
use tokio::net::{TcpListener, TcpStream, ToSocketAddrs};
use tokio::task::{JoinError, JoinSet, yield_now};
use tokio::time::{sleep, timeout};
use tokio_rustls::TlsAcceptor;
use tokio_rustls::server::TlsStream;

use super::RemoteTlsConfigHandle;
use crate::daemon::http::DaemonConnectInfo;

pub(crate) const DEFAULT_MAX_CONCURRENT_TLS_HANDSHAKES: usize = 64;
pub(crate) const DEFAULT_TLS_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

pub struct RemoteTlsListener {
    listener: TcpListener,
    config: Arc<ArcSwap<ServerConfig>>,
    handshakes: JoinSet<RemoteTlsHandshakeOutcome>,
    max_concurrent_handshakes: usize,
    handshake_timeout: Duration,
}

impl RemoteTlsListener {
    /// Bind a TCP socket and wrap accepted streams in bounded rustls handshakes.
    ///
    /// # Errors
    /// Returns [`io::Error`] when the TCP socket cannot bind.
    pub async fn bind<A>(addr: A, config: Arc<ServerConfig>) -> io::Result<Self>
    where
        A: ToSocketAddrs,
    {
        Self::bind_with_limits(
            addr,
            Arc::new(ArcSwap::from(config)),
            DEFAULT_MAX_CONCURRENT_TLS_HANDSHAKES,
            DEFAULT_TLS_HANDSHAKE_TIMEOUT,
        )
        .await
    }

    #[cfg(test)]
    pub(crate) async fn bind_reloadable<A>(
        addr: A,
        config: &RemoteTlsConfigHandle,
    ) -> io::Result<Self>
    where
        A: ToSocketAddrs,
    {
        Self::bind_reloadable_with_limits(
            addr,
            config,
            DEFAULT_MAX_CONCURRENT_TLS_HANDSHAKES,
            DEFAULT_TLS_HANDSHAKE_TIMEOUT,
        )
        .await
    }

    pub(crate) async fn bind_reloadable_with_limits<A>(
        addr: A,
        config: &RemoteTlsConfigHandle,
        max_concurrent_handshakes: usize,
        handshake_timeout: Duration,
    ) -> io::Result<Self>
    where
        A: ToSocketAddrs,
    {
        Self::bind_with_limits(
            addr,
            config.config_source(),
            max_concurrent_handshakes,
            handshake_timeout,
        )
        .await
    }

    async fn bind_with_limits<A>(
        addr: A,
        config: Arc<ArcSwap<ServerConfig>>,
        max_concurrent_handshakes: usize,
        handshake_timeout: Duration,
    ) -> io::Result<Self>
    where
        A: ToSocketAddrs,
    {
        validate_handshake_limits(max_concurrent_handshakes, handshake_timeout)?;
        Ok(Self {
            listener: TcpListener::bind(addr).await?,
            config,
            handshakes: JoinSet::new(),
            max_concurrent_handshakes,
            handshake_timeout,
        })
    }

    fn queue_handshake(&mut self, stream: TcpStream, addr: SocketAddr) {
        let acceptor = TlsAcceptor::from(self.config.load_full());
        let handshake_timeout = self.handshake_timeout;
        self.handshakes.spawn(async move {
            match timeout(handshake_timeout, acceptor.accept(stream)).await {
                Ok(Ok(stream)) => RemoteTlsHandshakeOutcome::Accepted(Box::new(stream), addr),
                Ok(Err(error)) => RemoteTlsHandshakeOutcome::Failed(addr, error),
                Err(_) => RemoteTlsHandshakeOutcome::TimedOut(addr),
            }
        });
    }

    async fn queue_tcp_accept(&mut self, accepted: io::Result<(TcpStream, SocketAddr)>) {
        match accepted {
            Ok((stream, addr)) => self.queue_handshake(stream, addr),
            Err(error) => handle_tcp_accept_error(error).await,
        }
    }

    #[cfg(test)]
    pub(crate) fn pending_handshake_count(&self) -> usize {
        self.handshakes.len()
    }

    async fn next_accepted_handshake(&mut self) -> Option<(TlsStream<TcpStream>, SocketAddr)> {
        if self.handshakes.is_empty() {
            let accepted = self.listener.accept().await;
            self.queue_tcp_accept(accepted).await;
            return None;
        }
        if self.handshakes.len() >= self.max_concurrent_handshakes {
            return completed_handshake(self.handshakes.join_next().await);
        }
        self.wait_for_handshake_or_tcp().await
    }

    async fn wait_for_handshake_or_tcp(&mut self) -> Option<(TlsStream<TcpStream>, SocketAddr)> {
        tokio::select! {
            completed = self.handshakes.join_next() => completed_handshake(completed),
            accepted = self.listener.accept() => {
                self.queue_tcp_accept(accepted).await;
                None
            }
        }
    }
}

impl Listener for RemoteTlsListener {
    type Io = TlsStream<TcpStream>;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        loop {
            if let Some(accepted) = self.next_accepted_handshake().await {
                return accepted;
            }
        }
    }

    fn local_addr(&self) -> io::Result<Self::Addr> {
        self.listener.local_addr()
    }
}

impl Connected<IncomingStream<'_, RemoteTlsListener>> for DaemonConnectInfo {
    fn connect_info(stream: IncomingStream<'_, RemoteTlsListener>) -> Self {
        Self::new(*stream.remote_addr())
    }
}

enum RemoteTlsHandshakeOutcome {
    Accepted(Box<TlsStream<TcpStream>>, SocketAddr),
    Failed(SocketAddr, io::Error),
    TimedOut(SocketAddr),
}

fn completed_handshake(
    completed: Option<Result<RemoteTlsHandshakeOutcome, JoinError>>,
) -> Option<(TlsStream<TcpStream>, SocketAddr)> {
    finish_handshake(joined_handshake(completed?)?)
}

fn joined_handshake(
    joined: Result<RemoteTlsHandshakeOutcome, JoinError>,
) -> Option<RemoteTlsHandshakeOutcome> {
    joined.inspect_err(log_handshake_task_error).ok()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_handshake_task_error(error: &JoinError) {
    tracing::warn!(%error, "remote TLS handshake task failed");
}

fn finish_handshake(
    outcome: RemoteTlsHandshakeOutcome,
) -> Option<(TlsStream<TcpStream>, SocketAddr)> {
    match outcome {
        RemoteTlsHandshakeOutcome::Accepted(stream, addr) => Some((*stream, addr)),
        RemoteTlsHandshakeOutcome::Failed(addr, error) => {
            handle_tls_handshake_error(addr, &error);
            None
        }
        RemoteTlsHandshakeOutcome::TimedOut(addr) => {
            handle_tls_handshake_timeout(addr);
            None
        }
    }
}

fn validate_handshake_limits(
    max_concurrent_handshakes: usize,
    handshake_timeout: Duration,
) -> io::Result<()> {
    if max_concurrent_handshakes == 0 || handshake_timeout.is_zero() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "remote TLS handshake limits must be non-zero",
        ));
    }
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(super) async fn handle_tcp_accept_error(error: io::Error) {
    if is_transient_accept_error(&error) {
        yield_now().await;
        return;
    }
    tracing::error!(%error, "remote TLS TCP accept failed");
    sleep(Duration::from_secs(1)).await;
}

pub(super) fn is_transient_accept_error(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::ConnectionRefused
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::Interrupted
            | io::ErrorKind::WouldBlock
    )
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(super) fn handle_tls_handshake_error(addr: SocketAddr, error: &io::Error) {
    tracing::debug!(
        remote_addr = %addr,
        %error,
        "remote TLS handshake failed"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn handle_tls_handshake_timeout(addr: SocketAddr) {
    tracing::debug!(
        remote_addr = %addr,
        "remote TLS handshake timed out"
    );
}
