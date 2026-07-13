use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::time::{Duration, Instant};

const DEFAULT_MAX_ENTRIES: usize = 4096;
const DEFAULT_WINDOW: Duration = Duration::from_mins(1);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemotePairingStatusRateLimitDecision {
    Allowed,
    Denied { audit: bool },
}

#[derive(Clone, Copy)]
struct AttemptWindow {
    started_at: Instant,
    count: u32,
    rejection_audited: bool,
}

impl AttemptWindow {
    const fn new(now: Instant) -> Self {
        Self {
            started_at: now,
            count: 1,
            rejection_audited: false,
        }
    }

    fn reset_if_expired(&mut self, now: Instant, window: Duration) {
        if now.saturating_duration_since(self.started_at) >= window {
            self.started_at = now;
            self.count = 0;
            self.rejection_audited = false;
        }
    }
}

#[derive(Clone)]
pub struct RemotePairingStatusRateLimiter {
    max_attempts: u32,
    max_entries: usize,
    window: Duration,
    ip_attempts: BTreeMap<String, AttemptWindow>,
    ip_order: VecDeque<String>,
    pairing_attempts: BTreeMap<String, AttemptWindow>,
    pairing_order: VecDeque<String>,
}

impl fmt::Debug for RemotePairingStatusRateLimiter {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RemotePairingStatusRateLimiter")
            .field("max_attempts", &self.max_attempts)
            .field("max_entries", &self.max_entries)
            .field("window", &self.window)
            .field("tracked_ip_addresses", &self.ip_attempts.len())
            .field("tracked_pairing_fingerprints", &self.pairing_attempts.len())
            .finish_non_exhaustive()
    }
}

impl RemotePairingStatusRateLimiter {
    #[must_use]
    pub fn new(max_attempts: u32) -> Self {
        Self::new_windowed(max_attempts, DEFAULT_MAX_ENTRIES, DEFAULT_WINDOW)
    }

    fn new_windowed(max_attempts: u32, max_entries: usize, window: Duration) -> Self {
        Self {
            max_attempts: max_attempts.max(1),
            max_entries: max_entries.max(1),
            window: if window.is_zero() {
                DEFAULT_WINDOW
            } else {
                window
            },
            ip_attempts: BTreeMap::new(),
            ip_order: VecDeque::new(),
            pairing_attempts: BTreeMap::new(),
            pairing_order: VecDeque::new(),
        }
    }

    #[cfg(test)]
    #[must_use]
    pub fn new_for_tests(max_attempts: u32) -> Self {
        Self::new(max_attempts)
    }

    #[cfg(test)]
    #[must_use]
    pub fn new_windowed_for_tests(max_attempts: u32, max_entries: usize, window: Duration) -> Self {
        Self::new_windowed(max_attempts, max_entries, window)
    }

    #[must_use]
    pub fn record_attempt(
        &mut self,
        remote_addr: &str,
        pairing_fingerprint: &str,
    ) -> RemotePairingStatusRateLimitDecision {
        self.record_attempt_at(remote_addr, pairing_fingerprint, Instant::now())
    }

    #[cfg(test)]
    #[must_use]
    pub fn record_attempt_at_for_tests(
        &mut self,
        remote_addr: &str,
        pairing_fingerprint: &str,
        now: Instant,
    ) -> RemotePairingStatusRateLimitDecision {
        self.record_attempt_at(remote_addr, pairing_fingerprint, now)
    }

    fn record_attempt_at(
        &mut self,
        remote_addr: &str,
        pairing_fingerprint: &str,
        now: Instant,
    ) -> RemotePairingStatusRateLimitDecision {
        reset_window_if_expired(&mut self.ip_attempts, remote_addr, now, self.window);
        reset_window_if_expired(
            &mut self.pairing_attempts,
            pairing_fingerprint,
            now,
            self.window,
        );

        let ip_limited = limit_reached(&self.ip_attempts, remote_addr, self.max_attempts);
        let pairing_limited = limit_reached(
            &self.pairing_attempts,
            pairing_fingerprint,
            self.max_attempts,
        );
        if ip_limited || pairing_limited {
            let mut audit = false;
            if ip_limited {
                audit |= mark_rejection_audited(&mut self.ip_attempts, remote_addr);
            }
            if pairing_limited {
                audit |= mark_rejection_audited(&mut self.pairing_attempts, pairing_fingerprint);
            }
            return RemotePairingStatusRateLimitDecision::Denied { audit };
        }

        record_bounded_attempt(
            &mut self.ip_attempts,
            &mut self.ip_order,
            remote_addr,
            self.max_entries,
            now,
        );
        record_bounded_attempt(
            &mut self.pairing_attempts,
            &mut self.pairing_order,
            pairing_fingerprint,
            self.max_entries,
            now,
        );
        RemotePairingStatusRateLimitDecision::Allowed
    }
}

fn reset_window_if_expired(
    attempts: &mut BTreeMap<String, AttemptWindow>,
    key: &str,
    now: Instant,
    window: Duration,
) {
    if let Some(attempt) = attempts.get_mut(key) {
        attempt.reset_if_expired(now, window);
    }
}

fn limit_reached(attempts: &BTreeMap<String, AttemptWindow>, key: &str, max_attempts: u32) -> bool {
    attempts
        .get(key)
        .is_some_and(|attempt| attempt.count >= max_attempts)
}

fn mark_rejection_audited(attempts: &mut BTreeMap<String, AttemptWindow>, key: &str) -> bool {
    let Some(attempt) = attempts.get_mut(key) else {
        return false;
    };
    if attempt.rejection_audited {
        return false;
    }
    attempt.rejection_audited = true;
    true
}

fn record_bounded_attempt(
    attempts: &mut BTreeMap<String, AttemptWindow>,
    order: &mut VecDeque<String>,
    key: &str,
    max_entries: usize,
    now: Instant,
) {
    if let Some(attempt) = attempts.get_mut(key) {
        attempt.count = attempt.count.saturating_add(1);
        return;
    }

    evict_until_room(attempts, order, max_entries);
    let key = key.to_string();
    order.push_back(key.clone());
    attempts.insert(key, AttemptWindow::new(now));
}

fn evict_until_room(
    attempts: &mut BTreeMap<String, AttemptWindow>,
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
