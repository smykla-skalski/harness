//! How the command line spells a role, a scope, and a pairing lifetime.
//!
//! These are the operator-facing names, deliberately hyphenated where the
//! stored value uses an underscore, so a flag reads the way a flag should
//! while the daemon records the value it already used.

use std::{num::NonZeroU64, str::FromStr};

use clap::ValueEnum;

use crate::daemon::remote::{RemoteAccessScope, RemoteRole};

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DaemonRemoteRole {
    #[value(name = "admin")]
    Admin,
    #[value(name = "operator")]
    Operator,
    #[value(name = "viewer")]
    Viewer,
    #[value(name = "execution-coordinator")]
    ExecutionCoordinator,
    #[value(name = "pairing-broker")]
    PairingBroker,
}

impl DaemonRemoteRole {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Admin => "admin",
            Self::Operator => "operator",
            Self::Viewer => "viewer",
            Self::ExecutionCoordinator => "execution-coordinator",
            Self::PairingBroker => "pairing-broker",
        }
    }
}

impl From<DaemonRemoteRole> for RemoteRole {
    fn from(value: DaemonRemoteRole) -> Self {
        match value {
            DaemonRemoteRole::Admin => Self::Admin,
            DaemonRemoteRole::Operator => Self::Operator,
            DaemonRemoteRole::Viewer => Self::Viewer,
            DaemonRemoteRole::ExecutionCoordinator => Self::ExecutionCoordinator,
            DaemonRemoteRole::PairingBroker => Self::PairingBroker,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DaemonRemoteScope {
    #[value(name = "read")]
    Read,
    #[value(name = "write")]
    Write,
    #[value(name = "admin")]
    Admin,
    #[value(name = "execute")]
    Execute,
    #[value(name = "pair-mint")]
    PairMint,
    #[value(name = "pair-manage")]
    PairManage,
}

impl DaemonRemoteScope {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Write => "write",
            Self::Admin => "admin",
            Self::Execute => "execute",
            Self::PairMint => "pair-mint",
            Self::PairManage => "pair-manage",
        }
    }
}

impl From<DaemonRemoteScope> for RemoteAccessScope {
    fn from(value: DaemonRemoteScope) -> Self {
        match value {
            DaemonRemoteScope::Read => Self::Read,
            DaemonRemoteScope::Write => Self::Write,
            DaemonRemoteScope::Admin => Self::Admin,
            DaemonRemoteScope::Execute => Self::Execute,
            DaemonRemoteScope::PairMint => Self::PairMint,
            DaemonRemoteScope::PairManage => Self::PairManage,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DaemonRemotePairTtl {
    seconds: NonZeroU64,
}

impl DaemonRemotePairTtl {
    #[must_use]
    pub const fn as_secs(self) -> u64 {
        self.seconds.get()
    }
}

impl FromStr for DaemonRemotePairTtl {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let (digits, multiplier) = if let Some(digits) = value.strip_suffix('s') {
            (digits, 1)
        } else if let Some(digits) = value.strip_suffix('m') {
            (digits, 60)
        } else if let Some(digits) = value.strip_suffix('h') {
            (digits, 60 * 60)
        } else {
            return Err("pairing ttl must end with s, m, or h".to_string());
        };

        if digits.is_empty() || !digits.chars().all(|character| character.is_ascii_digit()) {
            return Err("pairing ttl must start with a positive integer".to_string());
        }

        let count = digits
            .parse::<u64>()
            .map_err(|_| "pairing ttl value is too large".to_string())?;
        let seconds = count
            .checked_mul(multiplier)
            .ok_or_else(|| "pairing ttl value is too large".to_string())?;
        let seconds = NonZeroU64::new(seconds)
            .ok_or_else(|| "pairing ttl must be greater than zero".to_string())?;

        Ok(Self { seconds })
    }
}
