use std::collections::{BTreeMap, VecDeque};
use std::fmt;

use super::RemotePairingError;

const DEFAULT_MAX_ENTRIES: usize = 4096;

#[derive(Clone)]
pub struct RemotePairingRateLimiter {
    max_attempts: u32,
    max_entries: usize,
    ip_attempts: BTreeMap<String, u32>,
    ip_order: VecDeque<String>,
    code_attempts: BTreeMap<String, u32>,
    code_order: VecDeque<String>,
}

impl fmt::Debug for RemotePairingRateLimiter {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RemotePairingRateLimiter")
            .field("max_attempts", &self.max_attempts)
            .field("max_entries", &self.max_entries)
            .field("tracked_ip_addresses", &self.ip_attempts.len())
            .field("tracked_code_fingerprints", &self.code_attempts.len())
            .finish_non_exhaustive()
    }
}

impl RemotePairingRateLimiter {
    #[must_use]
    pub fn new(max_attempts: u32) -> Self {
        Self::new_bounded(max_attempts, DEFAULT_MAX_ENTRIES)
    }

    fn new_bounded(max_attempts: u32, max_entries: usize) -> Self {
        Self {
            max_attempts: max_attempts.max(1),
            max_entries: max_entries.max(1),
            ip_attempts: BTreeMap::new(),
            ip_order: VecDeque::new(),
            code_attempts: BTreeMap::new(),
            code_order: VecDeque::new(),
        }
    }

    #[cfg(test)]
    #[must_use]
    pub fn new_for_tests(max_attempts: u32) -> Self {
        Self::new(max_attempts)
    }

    #[cfg(test)]
    #[must_use]
    pub fn new_bounded_for_tests(max_attempts: u32, max_entries: usize) -> Self {
        Self::new_bounded(max_attempts, max_entries)
    }

    #[cfg(test)]
    #[must_use]
    pub fn tracked_attempts_for_tests(&self) -> (usize, usize) {
        (self.ip_attempts.len(), self.code_attempts.len())
    }

    /// Record one pairing attempt against independent address and code budgets.
    ///
    /// # Errors
    /// Returns [`RemotePairingError::RateLimited`] when either budget has
    /// reached the configured limit.
    pub fn record_attempt(
        &mut self,
        remote_addr: &str,
        code_fingerprint: &str,
    ) -> Result<(), RemotePairingError> {
        if limit_reached(&self.ip_attempts, remote_addr, self.max_attempts)
            || limit_reached(&self.code_attempts, code_fingerprint, self.max_attempts)
        {
            return Err(RemotePairingError::RateLimited);
        }

        record_bounded_attempt(
            &mut self.ip_attempts,
            &mut self.ip_order,
            remote_addr,
            self.max_entries,
        );
        record_bounded_attempt(
            &mut self.code_attempts,
            &mut self.code_order,
            code_fingerprint,
            self.max_entries,
        );
        Ok(())
    }
}

fn limit_reached(attempts: &BTreeMap<String, u32>, key: &str, max_attempts: u32) -> bool {
    attempts
        .get(key)
        .is_some_and(|count| *count >= max_attempts)
}

fn record_bounded_attempt(
    attempts: &mut BTreeMap<String, u32>,
    order: &mut VecDeque<String>,
    key: &str,
    max_entries: usize,
) {
    if !attempts.contains_key(key) {
        evict_until_room(attempts, order, max_entries);
        order.push_back(key.to_string());
    }
    let count = attempts.entry(key.to_string()).or_insert(0);
    *count = count.saturating_add(1);
}

fn evict_until_room(
    attempts: &mut BTreeMap<String, u32>,
    order: &mut VecDeque<String>,
    max_entries: usize,
) {
    while attempts.len() >= max_entries {
        let Some(oldest) = order.pop_front() else {
            attempts.clear();
            return;
        };
        attempts.remove(&oldest);
    }
}
