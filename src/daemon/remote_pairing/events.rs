//! What the daemon tells a remote client when a pairing changes.
//!
//! One channel carries every pairing change, and each subscriber is shown only
//! the ones it is entitled to. The alternative — a channel per client — would
//! move that decision to whoever publishes, which is the side that does not
//! know who is listening.

use serde::Serialize;

use super::RemotePairingInventoryEntry;

/// Why the pairing changed.
///
/// Named for what happened rather than for the resulting state, because the
/// state is already on the entry and a reader that wants to distinguish "this
/// link was just claimed" from "this link was already active when you
/// connected" cannot get that from the state alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RemotePairingChange {
    /// A link was issued.
    Minted,
    /// A device spent the code and became the pairing's device.
    Claimed,
    /// The pairing was cut off, or the link withdrawn before any claim.
    Revoked,
}

/// One pairing change, and enough to decide who may see it.
#[derive(Debug, Clone, Serialize)]
pub struct RemotePairingEvent {
    pub change: RemotePairingChange,
    pub pairing: RemotePairingInventoryEntry,
    /// The client that minted the pairing, absent for one created on the host.
    ///
    /// This copy is the routing key and is skipped because the entry above
    /// already carries the same value in its own `minted_by`, which the
    /// inventory route serializes too. Skipping it keeps one pairing spelled
    /// the same whether a reader received it here or read it over HTTP.
    ///
    /// It is emphatically not a secret held back: a subscriber only ever
    /// receives entries it is entitled to, so the identifier it can read off
    /// one is either its own or, for a caller entitled to everything, one the
    /// inventory would have told it anyway.
    #[serde(skip)]
    pub minted_by: Option<String>,
}

impl RemotePairingEvent {
    /// Whether a subscriber may see this change.
    ///
    /// The rule is the listing query's: a caller entitled to everything sees
    /// every change, and anyone else sees the pairings it minted. A pairing
    /// with no recorded minter reads as the host's and reaches only the former,
    /// which is the same direction the inventory takes and the only honest one
    /// — the daemon never wrote down who minted those.
    #[must_use]
    pub fn visible_to(&self, subscriber: Option<&str>) -> bool {
        match subscriber {
            None => true,
            Some(client_id) => self.minted_by.as_deref() == Some(client_id),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{RemotePairingChange, RemotePairingEvent};
    use crate::daemon::remote_pairing::{RemotePairingInventoryEntry, RemotePairingState};

    fn event(minted_by: Option<&str>) -> RemotePairingEvent {
        RemotePairingEvent {
            change: RemotePairingChange::Claimed,
            minted_by: minted_by.map(str::to_owned),
            pairing: RemotePairingInventoryEntry {
                pairing_id: "pair-1".to_owned(),
                state: RemotePairingState::Active,
                role: "operator".to_owned(),
                created_at: "2026-07-26T10:00:00Z".to_owned(),
                expires_at: "2026-07-26T10:10:00Z".to_owned(),
                claimed_at: None,
                revoked_at: None,
                minted_for: None,
                minted_by: None,
                device: None,
            },
        }
    }

    /// A caller entitled to everything is the host operator or an admin, and
    /// the inventory shows it every pairing.
    #[test]
    fn a_subscriber_entitled_to_everything_sees_every_change() {
        assert!(event(Some("broker-1")).visible_to(None));
        assert!(event(None).visible_to(None));
    }

    /// This is the whole of the isolation between two brokers sharing one
    /// daemon: neither may learn that the other's links exist.
    #[test]
    fn a_broker_sees_only_what_it_minted() {
        let mine = event(Some("broker-1"));
        assert!(mine.visible_to(Some("broker-1")));
        assert!(!mine.visible_to(Some("broker-2")));
    }

    /// A pairing minted on the host has nobody to attribute it to, and handing
    /// it to whichever broker happens to be listening would give one broker a
    /// link it never issued.
    #[test]
    fn a_host_pairing_reaches_no_broker() {
        assert!(!event(None).visible_to(Some("broker-1")));
    }

    /// The routing copy is skipped, and the entry's own is not. An earlier
    /// spelling of this asserted only that no `minted_by` appeared at the top
    /// level, against a fixture whose entry carried none either, so it would
    /// have passed whatever the nested field did.
    #[test]
    fn the_event_spells_a_pairing_the_way_the_inventory_does() {
        let mut minted = event(Some("broker-1"));
        minted.pairing.minted_by = Some("broker-1".to_owned());

        let encoded = serde_json::to_value(&minted).expect("serialize event");

        assert_eq!(encoded["change"], "claimed");
        assert!(
            encoded.as_object().is_some_and(|event| !event.contains_key("minted_by")),
            "the routing copy is redundant with the entry's own: {encoded}"
        );
        assert_eq!(
            encoded["pairing"]["minted_by"], "broker-1",
            "a pairing must read the same here as it does from the inventory"
        );
    }
}
