use std::io::{self, Write};
use std::path::{Path, PathBuf};

use harness_agents::runtime;
use harness_session::service as session_service;

use crate::adapters::RenderedHookResponse;

use super::{SignalIdentities, warn_formatted};

pub(super) struct HookSignalDelivery {
    claim: runtime::signal::PendingSignalDelivery,
    target: SignalAckTarget,
}

struct SignalAckTarget {
    orchestration_session: String,
    agent: String,
    project_dir: PathBuf,
}

pub(super) struct SignalContext {
    pub(super) text: String,
    pub(super) deliveries: Vec<HookSignalDelivery>,
}

#[derive(Default)]
pub(super) struct SignalInjection {
    pub(super) lines: Vec<String>,
    pub(super) deliveries: Vec<HookSignalDelivery>,
}

impl SignalInjection {
    pub(super) fn into_context(self) -> Option<SignalContext> {
        (!self.lines.is_empty()).then(|| SignalContext {
            text: self.lines.join("\n"),
            deliveries: self.deliveries,
        })
    }
}

pub(super) fn claim_signal_for_context(
    signal_dir: &Path,
    signal: &runtime::signal::Signal,
    ids: &SignalIdentities,
    project_dir: &Path,
    now: &str,
) -> Option<HookSignalDelivery> {
    let acknowledgment = runtime::signal::SignalAck {
        signal_id: signal.signal_id.clone(),
        acknowledged_at: now.to_string(),
        result: session_service::normalize_signal_ack_result(
            signal,
            runtime::signal::AckResult::Accepted,
        ),
        agent: ids.runtime_session.clone(),
        session_id: ids.orchestration_session.clone(),
        details: None,
    };
    let target = SignalAckTarget::new(ids, project_dir);
    match runtime::signal::claim_signal_acknowledgment(signal_dir, &acknowledgment) {
        Ok(runtime::signal::SignalAckClaim::Created(claim)) => handle_owned_claim(claim, target),
        Ok(runtime::signal::SignalAckClaim::Existing(stored)) => {
            target.record(&stored);
            None
        }
        Ok(runtime::signal::SignalAckClaim::Busy) => None,
        Err(error) => {
            warn_formatted(&format!(
                "failed to claim signal {}: {error} (session={})",
                signal.signal_id, ids.runtime_session,
            ));
            None
        }
    }
}

fn handle_owned_claim(
    claim: runtime::signal::PendingSignalDelivery,
    target: SignalAckTarget,
) -> Option<HookSignalDelivery> {
    if claim.acknowledgment().result == runtime::signal::AckResult::Accepted {
        return Some(HookSignalDelivery { claim, target });
    }
    commit_signal_delivery(HookSignalDelivery { claim, target });
    None
}

pub(super) fn write_hook_output(
    writer: &mut impl Write,
    rendered: &RenderedHookResponse,
    deliveries: Vec<HookSignalDelivery>,
) -> io::Result<()> {
    if !deliveries.is_empty()
        && (!rendered.additional_context_rendered || rendered.stdout.is_empty())
    {
        return Err(io::Error::new(
            io::ErrorKind::WriteZero,
            "rendered hook output omitted claimed signal context",
        ));
    }
    if !rendered.stdout.is_empty() {
        writer.write_all(rendered.stdout.as_bytes())?;
        writer.flush()?;
    }
    deliveries.into_iter().for_each(commit_signal_delivery);
    Ok(())
}

fn commit_signal_delivery(delivery: HookSignalDelivery) {
    let signal_id = delivery.claim.acknowledgment().signal_id.clone();
    match delivery.claim.commit() {
        Ok(stored) => delivery.target.record(&stored),
        Err(error) => warn_formatted(&format!(
            "failed to commit delivered signal {signal_id}: {error}"
        )),
    }
}

impl SignalAckTarget {
    fn new(ids: &SignalIdentities, project_dir: &Path) -> Self {
        Self {
            orchestration_session: ids.orchestration_session.clone(),
            agent: ids.agent.clone(),
            project_dir: project_dir.to_path_buf(),
        }
    }

    fn record(&self, acknowledgment: &runtime::signal::SignalAck) {
        if let Err(error) = session_service::record_signal_acknowledgment(
            &self.orchestration_session,
            &self.agent,
            &acknowledgment.signal_id,
            acknowledgment.result,
            &self.project_dir,
        ) {
            warn_formatted(&format!(
                "failed to persist signal acknowledgment {}: {error} (agent={})",
                acknowledgment.signal_id, self.agent
            ));
        }
    }
}
