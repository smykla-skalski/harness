//! The wire the harness client speaks to an ACP agent over.
//!
//! A spawned child talks stdio; a remote agent talks HTTP or WebSocket. Both
//! implement the SDK's `ConnectTo<Client>`, so everything downstream of
//! [`AcpTransport::connect`] - the client handlers, session bind, prompt loop -
//! is identical and never learns which transport carried the bytes.

use std::io;
use std::process::Child;

use agent_client_protocol::{Agent, ByteStreams, ConnectionTo, Result as AcpResult};
use agent_client_protocol_http::HttpClient;
use tokio::process::{ChildStdin, ChildStdout};
use tokio_util::compat::{TokioAsyncReadCompatExt, TokioAsyncWriteCompatExt};

use super::handlers::{ClientHandlers, connect_with_client_handlers};

pub(in crate::daemon::agent_acp) enum AcpTransport {
    Stdio { stdin: ChildStdin, stdout: ChildStdout },
    Http(HttpClient),
}

impl AcpTransport {
    /// Take the spawned child's piped stdio as the transport.
    pub(in crate::daemon::agent_acp) fn from_child(child: &mut Child) -> io::Result<Self> {
        let stdin = child
            .stdin
            .take()
            .expect("child stdin not captured; spawn with Stdio::piped()");
        let stdout = child
            .stdout
            .take()
            .expect("child stdout not captured; spawn with Stdio::piped()");
        Ok(Self::Stdio {
            stdin: ChildStdin::from_std(stdin)?,
            stdout: ChildStdout::from_std(stdout)?,
        })
    }

    /// Connect the harness client over this transport and run `main_fn` against
    /// the agent. Only one match arm runs, so moving `handlers` and `main_fn`
    /// into each is sound.
    pub(super) async fn connect<R>(
        self,
        handlers: ClientHandlers,
        main_fn: impl AsyncFnOnce(ConnectionTo<Agent>) -> AcpResult<R>,
    ) -> AcpResult<R> {
        match self {
            Self::Stdio { stdin, stdout } => {
                let transport = ByteStreams::new(stdin.compat_write(), stdout.compat());
                connect_with_client_handlers(transport, handlers, main_fn).await
            }
            Self::Http(client) => connect_with_client_handlers(client, handlers, main_fn).await,
        }
    }
}
