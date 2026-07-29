use std::collections::{BTreeMap, VecDeque};
use std::net::{IpAddr, Ipv4Addr};
use std::time::{Duration, Instant};

use axum::Json;
use axum::http::header::RETRY_AFTER;
use axum::http::{HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};

// The window matches the panel's OAuth-state TTL. Four starts can fill one
// browser's pending-state cookie, while monopolising the panel's 256-state
// global cap requires 64 independent source budgets rather than a few hosts.
const MAX_ATTEMPTS_PER_WINDOW: usize = 4;
const MAX_TRACKED_SOURCES: usize = 4_096;
const WINDOW: Duration = Duration::from_mins(10);
const ERROR_CODE: &str = "COMPANION_OAUTH_START_RATE_LIMIT";
const ERROR_MESSAGE: &str = "GitHub sign-in attempts are rate limited";

struct AttemptWindow {
    attempts: VecDeque<Instant>,
}

impl AttemptWindow {
    fn prune(&mut self, now: Instant, window: Duration) {
        while self
            .attempts
            .front()
            .is_some_and(|attempt| now.saturating_duration_since(*attempt) >= window)
        {
            self.attempts.pop_front();
        }
    }
}

pub(super) struct OAuthStartRateLimiter {
    sources: BTreeMap<IpAddr, AttemptWindow>,
    max_attempts: usize,
    max_sources: usize,
    window: Duration,
}

impl OAuthStartRateLimiter {
    pub(super) fn new() -> Self {
        Self::with_limits(MAX_ATTEMPTS_PER_WINDOW, MAX_TRACKED_SOURCES, WINDOW)
    }

    fn with_limits(max_attempts: usize, max_sources: usize, window: Duration) -> Self {
        debug_assert!(max_attempts > 0);
        debug_assert!(max_sources > 0);
        debug_assert!(!window.is_zero());
        Self {
            sources: BTreeMap::new(),
            max_attempts,
            max_sources,
            window,
        }
    }

    pub(super) fn admit(&mut self, source: IpAddr, now: Instant) -> Result<(), u64> {
        let source = source_budget_key(source);
        if let Some(attempts) = self.sources.get_mut(&source) {
            attempts.prune(now, self.window);
            if attempts.attempts.len() < self.max_attempts {
                attempts.attempts.push_back(now);
                return Ok(());
            }
            let elapsed = attempts.attempts.front().map_or(Duration::ZERO, |attempt| {
                now.saturating_duration_since(*attempt)
            });
            return Err(retry_after_seconds(self.window.saturating_sub(elapsed)));
        }

        if self.sources.len() >= self.max_sources {
            for attempts in self.sources.values_mut() {
                attempts.prune(now, self.window);
            }
            self.sources
                .retain(|_, attempts| !attempts.attempts.is_empty());
        }
        if self.sources.len() >= self.max_sources {
            let retry_after = self
                .sources
                .values()
                .filter_map(|attempts| attempts.attempts.front())
                .map(|attempt| {
                    let elapsed = now.saturating_duration_since(*attempt);
                    retry_after_seconds(self.window.saturating_sub(elapsed))
                })
                .min()
                .unwrap_or_else(|| retry_after_seconds(self.window));
            return Err(retry_after);
        }

        self.sources.insert(
            source,
            AttemptWindow {
                attempts: VecDeque::from([now]),
            },
        );
        Ok(())
    }
}

fn source_budget_key(source: IpAddr) -> IpAddr {
    match source {
        IpAddr::V4(address) => {
            if address.is_loopback() {
                IpAddr::V4(Ipv4Addr::LOCALHOST)
            } else {
                IpAddr::V4(address)
            }
        }
        IpAddr::V6(address) => {
            if let Some(address) = address.to_ipv4_mapped() {
                return if address.is_loopback() {
                    IpAddr::V4(Ipv4Addr::LOCALHOST)
                } else {
                    IpAddr::V4(address)
                };
            }

            // A single IPv6 client can rotate privacy addresses inside its routed /64.
            // Keeping the full address would hand every rotation a fresh budget.
            IpAddr::V6((u128::from(address) & (u128::MAX << 64)).into())
        }
    }
}

fn retry_after_seconds(remaining: Duration) -> u64 {
    remaining
        .as_secs()
        .saturating_add(u64::from(remaining.subsec_nanos() > 0))
        .max(1)
}

pub(super) fn rate_limited_response(retry_after_seconds: u64) -> Response {
    let mut response = (
        StatusCode::TOO_MANY_REQUESTS,
        Json(serde_json::json!({
            "error": {
                "code": ERROR_CODE,
                "message": ERROR_MESSAGE,
            }
        })),
    )
        .into_response();
    response
        .headers_mut()
        .insert(RETRY_AFTER, HeaderValue::from(retry_after_seconds));
    response
}

#[cfg(test)]
mod tests {
    use super::{Duration, Instant, IpAddr, OAuthStartRateLimiter};

    fn source(last_octet: u8) -> IpAddr {
        IpAddr::from([192, 0, 2, last_octet])
    }

    #[test]
    fn allows_four_attempts_per_state_lifetime_then_denies_the_source() {
        let now = Instant::now();
        let mut limiter = OAuthStartRateLimiter::new();

        for _ in 0..4 {
            assert_eq!(limiter.admit(source(1), now), Ok(()));
        }

        assert_eq!(limiter.admit(source(1), now), Err(600));
    }

    #[test]
    fn one_limited_source_does_not_consume_another_sources_budget() {
        let now = Instant::now();
        let mut limiter = OAuthStartRateLimiter::new();

        for _ in 0..4 {
            limiter.admit(source(1), now).expect("source one admitted");
        }

        assert!(limiter.admit(source(1), now).is_err());
        assert_eq!(limiter.admit(source(2), now), Ok(()));
    }

    #[test]
    fn ipv6_privacy_addresses_in_one_prefix_share_a_budget() {
        let now = Instant::now();
        let mut limiter = OAuthStartRateLimiter::with_limits(1, 4, Duration::from_secs(60));
        let first = "2001:db8:1:2::1".parse().expect("first IPv6 address");
        let rotated = "2001:db8:1:2::2".parse().expect("rotated IPv6 address");
        let other_prefix = "2001:db8:1:3::1".parse().expect("other IPv6 prefix");

        assert_eq!(limiter.admit(first, now), Ok(()));
        assert_eq!(limiter.admit(rotated, now), Err(60));
        assert_eq!(limiter.admit(other_prefix, now), Ok(()));
    }

    #[test]
    fn ipv4_mapped_ipv6_keeps_distinct_ipv4_budgets() {
        let now = Instant::now();
        let mut limiter = OAuthStartRateLimiter::with_limits(1, 4, Duration::from_secs(60));
        let first = "::ffff:192.0.2.1".parse().expect("first mapped address");
        let second = "::ffff:192.0.2.2".parse().expect("second mapped address");

        assert_eq!(limiter.admit(first, now), Ok(()));
        assert_eq!(limiter.admit(source(1), now), Err(60));
        assert_eq!(limiter.admit(second, now), Ok(()));
    }

    #[test]
    fn ipv4_loopback_representations_share_a_budget() {
        let now = Instant::now();
        let mut limiter = OAuthStartRateLimiter::with_limits(1, 4, Duration::from_secs(60));
        let first = IpAddr::from([127, 0, 0, 2]);
        let native = IpAddr::from([127, 255, 255, 254]);
        let mapped = "::ffff:127.42.0.1"
            .parse()
            .expect("mapped loopback address");

        assert_eq!(limiter.admit(first, now), Ok(()));
        assert_eq!(limiter.admit(native, now), Err(60));
        assert_eq!(limiter.admit(mapped, now), Err(60));
    }

    #[test]
    fn an_expired_window_starts_with_a_fresh_attempt() {
        let now = Instant::now();
        let mut limiter = OAuthStartRateLimiter::new();

        for _ in 0..4 {
            limiter.admit(source(1), now).expect("attempt admitted");
        }

        assert_eq!(
            limiter.admit(source(1), now + Duration::from_secs(599)),
            Err(1)
        );
        assert_eq!(
            limiter.admit(source(1), now + Duration::from_secs(600)),
            Ok(())
        );
    }

    #[test]
    fn a_window_boundary_cannot_double_one_sources_live_budget() {
        let now = Instant::now();
        let mut limiter = OAuthStartRateLimiter::with_limits(2, 4, Duration::from_secs(60));

        assert_eq!(limiter.admit(source(1), now), Ok(()));
        assert_eq!(
            limiter.admit(source(1), now + Duration::from_secs(59)),
            Ok(())
        );
        assert_eq!(
            limiter.admit(source(1), now + Duration::from_secs(60)),
            Ok(())
        );
        assert_eq!(
            limiter.admit(source(1), now + Duration::from_secs(60)),
            Err(59)
        );
    }

    #[test]
    fn capacity_refuses_new_sources_without_evicting_active_budgets() {
        let now = Instant::now();
        let mut limiter = OAuthStartRateLimiter::with_limits(1, 2, Duration::from_secs(60));

        assert_eq!(limiter.admit(source(1), now), Ok(()));
        assert_eq!(limiter.admit(source(2), now), Ok(()));
        assert_eq!(limiter.admit(source(3), now), Err(60));
        assert_eq!(limiter.sources.len(), 2);
        assert!(limiter.sources.contains_key(&source(1)));
        assert!(limiter.sources.contains_key(&source(2)));
        assert_eq!(limiter.admit(source(1), now), Err(60));

        assert_eq!(
            limiter.admit(source(3), now + Duration::from_secs(60)),
            Ok(())
        );
        assert_eq!(limiter.sources.len(), 1);
        assert!(limiter.sources.contains_key(&source(3)));
    }
}
