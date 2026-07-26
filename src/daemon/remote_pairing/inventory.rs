//! What a link became, for a caller entitled to ask.
//!
//! The public status endpoint answers about one pairing and deliberately hides
//! whether an unknown id exists. This is the other view: an authenticated
//! caller enumerating the links it is responsible for, and what is on the other
//! end of the ones that were claimed.

use serde::Serialize;

use super::RemotePairingSubject;

/// Where a link has got to.
///
/// Ordered by how far the link has travelled, so a reader can see that
/// `Revoked` overrides everything else: a device whose credential was cut off
/// is revoked whether or not its link had also expired.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum RemotePairingState {
    /// Minted, still claimable, nobody has used it.
    Pending,
    /// Claimed, but the device has not made an authenticated request since.
    Claimed,
    /// Claimed, and the device has been seen using its credential.
    Active,
    /// The claim window closed with nobody claiming it.
    Expired,
    /// The credential was cut off, or the link was revoked before any claim.
    Revoked,
}

impl RemotePairingState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Claimed => "claimed",
            Self::Active => "active",
            Self::Expired => "expired",
            Self::Revoked => "revoked",
        }
    }

    /// Decide the state from the columns that record it.
    ///
    /// `revoked_at` wins over everything: a cut-off device must never read as
    /// active because its row also happens to look claimed, and a link revoked
    /// before it was claimed must not read as pending and invite someone to
    /// wait for a claim that can no longer happen.
    #[must_use]
    pub fn derive(observed: &RemotePairingObservation<'_>) -> Self {
        if observed.revoked_at.is_some() {
            return Self::Revoked;
        }
        if observed.claimed_at.is_some() {
            // A claimed link whose device has never been seen is not yet doing
            // anything, and telling those apart is what lets someone notice a
            // claim that went to a device that then failed to connect.
            return if observed.last_seen_at.is_some() {
                Self::Active
            } else {
                Self::Claimed
            };
        }
        if observed.expired {
            return Self::Expired;
        }
        Self::Pending
    }
}

/// The stored facts a state is derived from, named so the derivation reads as
/// the rule it is rather than as four positional booleans.
#[derive(Debug, Clone, Copy)]
pub struct RemotePairingObservation<'a> {
    pub claimed_at: Option<&'a str>,
    pub revoked_at: Option<&'a str>,
    pub last_seen_at: Option<&'a str>,
    pub expired: bool,
}

/// The device a claimed link became.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, utoipa::ToSchema)]
pub struct RemotePairingDevice {
    pub client_id: String,
    pub display_name: String,
    pub platform: String,
    /// Absent until the device makes its first authenticated request.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_seen_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<String>,
}

/// One link and what became of it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, utoipa::ToSchema)]
pub struct RemotePairingInventoryEntry {
    pub pairing_id: String,
    /// The enum rather than its label, so the schema enumerates what a reader
    /// may receive. The wire value is the same `snake_case` string either way.
    pub state: RemotePairingState,
    pub role: String,
    pub created_at: String,
    pub expires_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claimed_at: Option<String>,
    /// When it was revoked, from whichever end carries it. A link withdrawn
    /// before any claim has no device to read it from, so without this a
    /// reader could see `revoked` and not when.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<String>,
    /// The identity the link was minted for. Absent for a link created on the
    /// host, which belongs to whoever ran the command rather than to anyone the
    /// daemon authenticated.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minted_for: Option<RemotePairingSubject>,
    /// The client that minted it, absent for the same reason.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minted_by: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device: Option<RemotePairingDevice>,
}

#[cfg(test)]
mod tests {
    use super::{RemotePairingObservation, RemotePairingState};

    fn observed(
        claimed_at: Option<&'static str>,
        revoked_at: Option<&'static str>,
        last_seen_at: Option<&'static str>,
        expired: bool,
    ) -> RemotePairingObservation<'static> {
        RemotePairingObservation {
            claimed_at,
            revoked_at,
            last_seen_at,
            expired,
        }
    }

    #[test]
    fn an_unclaimed_link_is_pending_until_its_window_closes() {
        assert_eq!(
            RemotePairingState::derive(&observed(None, None, None, false)),
            RemotePairingState::Pending
        );
        assert_eq!(
            RemotePairingState::derive(&observed(None, None, None, true)),
            RemotePairingState::Expired
        );
    }

    /// Telling these apart is the point of having both: a claim that reached a
    /// device which then never connected looks identical to a working pairing
    /// unless the last-seen column is consulted.
    #[test]
    fn a_claim_becomes_active_only_once_the_device_has_been_seen() {
        assert_eq!(
            RemotePairingState::derive(&observed(Some("t1"), None, None, false)),
            RemotePairingState::Claimed
        );
        assert_eq!(
            RemotePairingState::derive(&observed(Some("t1"), None, Some("t2"), false)),
            RemotePairingState::Active
        );
    }

    /// A cut-off device that also looks claimed, active, or expired still reads
    /// as revoked. Anything else would show a credential as usable after
    /// somebody deliberately withdrew it.
    #[test]
    fn revocation_outranks_every_other_state() {
        for (claimed, seen, expired) in [
            (None, None, false),
            (None, None, true),
            (Some("t1"), None, false),
            (Some("t1"), Some("t2"), false),
            (Some("t1"), Some("t2"), true),
        ] {
            assert_eq!(
                RemotePairingState::derive(&observed(claimed, Some("t3"), seen, expired)),
                RemotePairingState::Revoked,
                "claimed={claimed:?} seen={seen:?} expired={expired}"
            );
        }
    }

    #[test]
    fn every_state_has_a_stable_label() {
        for (state, label) in [
            (RemotePairingState::Pending, "pending"),
            (RemotePairingState::Claimed, "claimed"),
            (RemotePairingState::Active, "active"),
            (RemotePairingState::Expired, "expired"),
            (RemotePairingState::Revoked, "revoked"),
        ] {
            assert_eq!(state.as_str(), label);
        }
    }
}
