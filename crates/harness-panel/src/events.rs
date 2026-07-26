//! Changes the panel pushes out, and the hub every watcher subscribes to.
//!
//! One channel carries everything, and each browser socket is shown only what
//! its viewer is entitled to. The alternative — a channel per signed-in person
//! — would put that decision on the publisher, which is the side that has no
//! idea who is listening.
//!
//! Attribution is resolved once, where the change arrives, rather than once per
//! watcher. The panel's own table is the only place the account behind a
//! pairing is recorded, and asking it again for every open socket would make a
//! single claim cost one query per browser.

use std::sync::Arc;

use tokio::sync::broadcast;

use crate::daemon_client::pairings::DaemonPairing;

/// How far behind a watcher may fall before the channel starts dropping what it
/// has not read. Generous: pairing changes are rare, and a browser this far
/// behind is one whose socket is about to be closed anyway.
const BACKLOG: usize = 64;

/// One pairing change, with the account the panel minted it for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingChanged {
    /// `minted`, `claimed`, or `revoked`, as the daemon spelled it. Passed
    /// through rather than parsed, for the same reason the pairing's state is:
    /// the daemon owns this vocabulary, and a change it grows should reach the
    /// page as itself instead of being flattened into whatever the panel
    /// guessed.
    pub change: String,
    pub pairing: DaemonPairing,
    /// Absent for a pairing the panel has no record of, which only the owner is
    /// shown at all — the same rule the pairing list applies, and for the same
    /// reason: the panel does not know who it was minted for.
    pub account_id: Option<String>,
}

/// Something a watcher needs to act on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PanelChange {
    /// The panel's own link to the daemon has just come up.
    ///
    /// Whatever changed while it was down was never announced and never will
    /// be, so this says only that a watcher's picture may be stale. Acting on
    /// it means re-reading the list, which is the request that answers what is
    /// true now.
    Resynced,
    Pairing(Arc<PairingChanged>),
}

/// Where changes are announced and where watchers pick them up.
#[derive(Debug, Clone)]
pub struct PanelEvents {
    sender: broadcast::Sender<PanelChange>,
}

impl Default for PanelEvents {
    fn default() -> Self {
        Self::new()
    }
}

impl PanelEvents {
    #[must_use]
    pub fn new() -> Self {
        Self {
            sender: broadcast::channel(BACKLOG).0,
        }
    }

    /// Start receiving from here on. Nothing is replayed: a watcher that needs
    /// the current state reads the list, and this only tells it when that
    /// answer has stopped being true.
    #[must_use]
    pub fn watch(&self) -> broadcast::Receiver<PanelChange> {
        self.sender.subscribe()
    }

    /// Tell every watcher, if there are any.
    ///
    /// A send with no receivers is the ordinary case — a panel nobody has open
    /// — and not a failure worth reporting.
    pub fn announce(&self, change: PanelChange) {
        let _ = self.sender.send(change);
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::{PairingChanged, PanelChange, PanelEvents};
    use crate::daemon_client::pairings::DaemonPairing;

    fn pairing_change() -> PanelChange {
        PanelChange::Pairing(Arc::new(PairingChanged {
            change: "claimed".to_owned(),
            account_id: Some("acc_1".to_owned()),
            pairing: DaemonPairing {
                pairing_id: "pair-1".to_owned(),
                state: "active".to_owned(),
                role: "operator".to_owned(),
                created_at: "2026-07-26T10:00:00Z".to_owned(),
                expires_at: "2026-07-26T10:10:00Z".to_owned(),
                claimed_at: Some("2026-07-26T10:01:00Z".to_owned()),
                revoked_at: None,
                device: None,
            },
        }))
    }

    /// Two browsers watching the same panel both have to be told, or one of
    /// them sits on a link that was claimed minutes ago.
    #[tokio::test]
    async fn every_watcher_receives_the_same_change() {
        let events = PanelEvents::new();
        let mut first = events.watch();
        let mut second = events.watch();

        events.announce(pairing_change());

        assert_eq!(first.recv().await.expect("first watcher"), pairing_change());
        assert_eq!(
            second.recv().await.expect("second watcher"),
            pairing_change()
        );
    }

    /// A watcher that subscribes after the fact has missed it. That is the
    /// contract rather than an oversight: it reads the list on connect, and
    /// replaying would hand it a change it had already accounted for.
    #[tokio::test]
    async fn nothing_is_replayed_to_a_watcher_that_arrives_later() {
        let events = PanelEvents::new();
        events.announce(PanelChange::Resynced);

        let mut late = events.watch();
        events.announce(pairing_change());

        assert_eq!(
            late.recv().await.expect("the later change"),
            pairing_change()
        );
    }

    /// The panel usually has nobody watching, and announcing into that must not
    /// look like anything going wrong.
    #[test]
    fn announcing_with_nobody_watching_is_not_a_failure() {
        PanelEvents::new().announce(PanelChange::Resynced);
    }
}
