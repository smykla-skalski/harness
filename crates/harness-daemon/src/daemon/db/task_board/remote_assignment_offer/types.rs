use chrono::{DateTime, Utc};

use super::PreparedRemoteOffer;

pub(super) enum OfferPreparation {
    Stale(&'static str),
    Unavailable(&'static str),
    Ready(Box<PreparedRemoteOffer>),
}

pub(super) struct OfferTimes {
    pub(super) offered_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct TaskBoardRemoteOfferWindow<'a> {
    pub(super) offered: &'a str,
    pub(super) lease_expires: &'a str,
    pub(super) deadline: &'a str,
}

impl<'a> TaskBoardRemoteOfferWindow<'a> {
    pub(crate) const fn new(
        offered_at: &'a str,
        lease_expires_at: &'a str,
        deadline_at: &'a str,
    ) -> Self {
        Self {
            offered: offered_at,
            lease_expires: lease_expires_at,
            deadline: deadline_at,
        }
    }
}
