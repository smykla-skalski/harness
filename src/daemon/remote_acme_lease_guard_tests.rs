use std::io::{self, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tokio::time::timeout;
use tracing_subscriber::fmt::writer::MakeWriter;
use tracing_subscriber::layer::SubscriberExt as _;

use super::{RemoteAcmeChallengeLeaseGuard, observe_background_cleanup};
use crate::daemon::remote_acme_cleanup::RemoteAcmeCleanupTracker;
use crate::daemon::remote_acme_issuer::{
    RemoteAcmeChallengeMaterial, RemoteAcmeChallengeProvisioner,
};

#[tokio::test(flavor = "current_thread")]
async fn background_cleanup_failure_has_accurate_redacted_log_context() {
    let output = SharedOutput::default();
    let subscriber = tracing_subscriber::registry().with(
        tracing_subscriber::fmt::layer()
            .with_ansi(false)
            .with_target(false)
            .with_writer(output.clone()),
    );
    let _subscriber = tracing::subscriber::set_default(subscriber);
    let tracker = RemoteAcmeCleanupTracker::default();
    let mut leases =
        RemoteAcmeChallengeLeaseGuard::new(Arc::new(FailingProvisioner), tracker.clone());
    leases.push(());

    leases.cleanup_in_background();
    timeout(Duration::from_secs(2), tracker.wait_for_cleanup())
        .await
        .expect("background cleanup did not finish");
    let logs = wait_for_log(
        &output,
        "remote ACME challenge cleanup after successful issuance failed",
    )
    .await;

    assert!(
        logs.contains("remote ACME challenge cleanup after successful issuance failed"),
        "missing accurate cleanup context: {logs}"
    );
    assert!(!logs.contains("after cancellation failed"));
    assert!(logs.contains("<redacted>"));
    assert!(!logs.contains("cleanup-secret"));
}

#[tokio::test(flavor = "current_thread")]
async fn background_cleanup_observation_failure_is_explicit() {
    let output = SharedOutput::default();
    let subscriber = tracing_subscriber::registry().with(
        tracing_subscriber::fmt::layer()
            .with_ansi(false)
            .with_target(false)
            .with_writer(output.clone()),
    );
    let _subscriber = tracing::subscriber::set_default(subscriber);
    let (completion, observation) = tokio::sync::oneshot::channel();
    drop(completion);

    observe_background_cleanup(observation).await;
    let logs = output.contents();

    assert!(
        logs.contains("remote ACME challenge cleanup observation after successful issuance failed"),
        "missing explicit observation failure context: {logs}"
    );
}

async fn wait_for_log(output: &SharedOutput, expected: &str) -> String {
    timeout(Duration::from_secs(2), async {
        loop {
            let logs = output.contents();
            if logs.contains(expected) {
                return logs;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("missing expected cleanup log: {}", output.contents()))
}

#[derive(Clone, Copy)]
struct FailingProvisioner;

#[async_trait]
impl RemoteAcmeChallengeProvisioner for FailingProvisioner {
    type Lease = ();

    async fn present(&self, _material: RemoteAcmeChallengeMaterial) -> Result<(), String> {
        Ok(())
    }

    async fn cleanup(&self, _lease: ()) -> Result<(), String> {
        Err("provider cleanup token=cleanup-secret".to_string())
    }
}

#[derive(Clone, Default)]
struct SharedOutput(Arc<Mutex<Vec<u8>>>);

impl SharedOutput {
    fn contents(&self) -> String {
        String::from_utf8(self.0.lock().expect("buffer lock").clone()).expect("utf8 output")
    }
}

impl<'a> MakeWriter<'a> for SharedOutput {
    type Writer = SharedOutputWriter;

    fn make_writer(&'a self) -> Self::Writer {
        SharedOutputWriter(Arc::clone(&self.0))
    }
}

struct SharedOutputWriter(Arc<Mutex<Vec<u8>>>);

impl Write for SharedOutputWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.0
            .lock()
            .expect("buffer lock")
            .extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
