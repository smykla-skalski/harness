use std::hash::{DefaultHasher, Hash, Hasher as _};
use std::time::{Duration, Instant};

const REPEAT_WARNING_INTERVAL: Duration = Duration::from_mins(1);
const MAX_TRACKED_KEYS: usize = 64;

#[derive(Debug, Default)]
pub struct RepeatedLogGate {
    warning_times: Vec<(u64, Instant)>,
    overflow_warning: Option<Instant>,
}

impl RepeatedLogGate {
    #[must_use]
    pub fn should_warn(&mut self, key: u64) -> bool {
        self.should_warn_at(key, Instant::now())
    }

    fn should_warn_at(&mut self, key: u64, now: Instant) -> bool {
        if let Some((_, last_warning)) = self
            .warning_times
            .iter_mut()
            .find(|(tracked, _)| tracked == &key)
        {
            if now.saturating_duration_since(*last_warning) < REPEAT_WARNING_INTERVAL {
                return false;
            }
            *last_warning = now;
            return true;
        }
        if self.warning_times.len() < MAX_TRACKED_KEYS {
            self.warning_times.push((key, now));
            return true;
        }
        if self
            .overflow_warning
            .is_some_and(|last| now.saturating_duration_since(last) < REPEAT_WARNING_INTERVAL)
        {
            return false;
        }
        self.overflow_warning = Some(now);
        true
    }
}

#[must_use]
pub fn log_identity<T: Hash + ?Sized>(value: &T) -> u64 {
    let mut hasher = DefaultHasher::new();
    value.hash(&mut hasher);
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::{MAX_TRACKED_KEYS, RepeatedLogGate, log_identity};

    #[test]
    fn repeated_key_warns_once_per_interval() {
        let mut gate = RepeatedLogGate::default();
        let start = Instant::now();

        let key = log_identity("same");
        assert!(gate.should_warn_at(key, start));
        assert!(!gate.should_warn_at(key, start + Duration::from_secs(59)));
        assert!(gate.should_warn_at(key, start + Duration::from_mins(1)));
    }

    #[test]
    fn changed_key_warns_immediately() {
        let mut gate = RepeatedLogGate::default();
        let start = Instant::now();

        let first = log_identity("first");
        let second = log_identity("second");
        assert!(gate.should_warn_at(first, start));
        assert!(gate.should_warn_at(second, start));
        assert!(!gate.should_warn_at(second, start));
    }

    #[test]
    fn alternating_keys_are_throttled_independently() {
        let mut gate = RepeatedLogGate::default();
        let start = Instant::now();

        let first = log_identity("first");
        let second = log_identity("second");
        assert!(gate.should_warn_at(first, start));
        assert!(gate.should_warn_at(second, start));
        assert!(!gate.should_warn_at(first, start));
        assert!(!gate.should_warn_at(second, start));
    }

    #[test]
    fn high_cardinality_overflow_has_one_shared_warning_budget() {
        let mut gate = RepeatedLogGate::default();
        let start = Instant::now();

        for key in 0..MAX_TRACKED_KEYS {
            assert!(gate.should_warn_at(u64::try_from(key).expect("key"), start));
        }
        assert!(gate.should_warn_at(10_000, start));
        assert!(!gate.should_warn_at(10_001, start));
        assert!(gate.should_warn_at(10_001, start + Duration::from_mins(1)));
    }
}
