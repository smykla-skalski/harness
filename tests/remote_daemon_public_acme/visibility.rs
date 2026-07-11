use std::fmt;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use futures_util::future::join_all;
use tokio::time::{Instant, sleep, timeout};

use super::aftermarket::PublicARecordVisibility;
use super::visibility_system::SystemAuthoritativeARecordObserver;

const TIMEOUT_ENV: &str = "HARNESS_REMOTE_ACME_DNS_VISIBILITY_TIMEOUT_SECONDS";
const POLL_INTERVAL_ENV: &str = "HARNESS_REMOTE_ACME_DNS_VISIBILITY_POLL_SECONDS";
const STABLE_POLLS_ENV: &str = "HARNESS_REMOTE_ACME_DNS_VISIBILITY_STABLE_POLLS";
const DEFAULT_TIMEOUT: Duration = Duration::from_mins(5);
const DEFAULT_POLL_INTERVAL: Duration = Duration::from_secs(5);
const DEFAULT_STABLE_POLLS: usize = 3;

#[derive(Clone)]
pub struct AuthoritativeARecordVisibility {
    zone_name: String,
    timeout: Duration,
    poll_interval: Duration,
    stable_polls: usize,
    observer: Arc<dyn AuthoritativeARecordObserver>,
}

impl AuthoritativeARecordVisibility {
    pub fn from_environment(zone_name: &str) -> Result<Self, String> {
        Ok(Self {
            zone_name: zone_name.to_string(),
            timeout: duration_from_env(TIMEOUT_ENV, DEFAULT_TIMEOUT)?,
            poll_interval: duration_from_env(POLL_INTERVAL_ENV, DEFAULT_POLL_INTERVAL)?,
            stable_polls: positive_usize_from_env(STABLE_POLLS_ENV, DEFAULT_STABLE_POLLS)?,
            observer: Arc::new(SystemAuthoritativeARecordObserver),
        })
    }

    #[cfg(test)]
    fn new_with_observer(
        zone_name: &str,
        timeout: Duration,
        poll_interval: Duration,
        stable_polls: usize,
        observer: Arc<dyn AuthoritativeARecordObserver>,
    ) -> Self {
        Self {
            zone_name: zone_name.to_string(),
            timeout,
            poll_interval,
            stable_polls,
            observer,
        }
    }

    async fn observe(
        &self,
        endpoints: &[AuthoritativeDnsEndpoint],
        name: &str,
        address: std::net::Ipv4Addr,
        query_timeout: Duration,
    ) -> Vec<AuthoritativeDnsObservation> {
        join_all(endpoints.iter().map(|endpoint| async move {
            let result = match timeout(
                query_timeout,
                self.observer.address_present(endpoint, name, address),
            )
            .await
            {
                Ok(result) => result,
                Err(_) => Err("query exceeded remaining visibility timeout".to_string()),
            };
            AuthoritativeDnsObservation {
                endpoint: endpoint.clone(),
                result,
            }
        }))
        .await
    }
}

impl fmt::Debug for AuthoritativeARecordVisibility {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AuthoritativeARecordVisibility")
            .field("zone_name", &self.zone_name)
            .field("timeout", &self.timeout)
            .field("poll_interval", &self.poll_interval)
            .field("stable_polls", &self.stable_polls)
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl PublicARecordVisibility for AuthoritativeARecordVisibility {
    async fn wait_for(
        &self,
        name: &str,
        address: std::net::Ipv4Addr,
        present: bool,
    ) -> Result<(), String> {
        let endpoints = self.observer.discover_endpoints(&self.zone_name).await?;
        if endpoints.is_empty() {
            return Err(format!(
                "authoritative DNS lookup for {} returned no endpoints",
                self.zone_name
            ));
        }
        let fqdn = format!("{}.", name.trim_end_matches('.'));
        let deadline = Instant::now() + self.timeout;
        let mut stable_polls = 0;
        let mut observations = Vec::new();
        loop {
            let now = Instant::now();
            if now >= deadline {
                return Err(visibility_timeout_error(
                    name,
                    present,
                    self.timeout,
                    stable_polls,
                    self.stable_polls,
                    &observations,
                ));
            }
            observations = self
                .observe(&endpoints, &fqdn, address, deadline - now)
                .await;
            if all_observations_match(present, &observations) {
                stable_polls += 1;
                if stable_polls == self.stable_polls {
                    return Ok(());
                }
            } else {
                stable_polls = 0;
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(visibility_timeout_error(
                    name,
                    present,
                    self.timeout,
                    stable_polls,
                    self.stable_polls,
                    &observations,
                ));
            }
            sleep(self.poll_interval.min(deadline - now)).await;
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct AuthoritativeDnsEndpoint {
    pub(super) name: String,
    pub(super) address: IpAddr,
}

impl AuthoritativeDnsEndpoint {
    pub(super) fn new(name: &str, address: IpAddr) -> Self {
        Self {
            name: name.trim_end_matches('.').to_string(),
            address,
        }
    }

    pub(super) fn label(&self) -> String {
        format!("{}@{}", self.name, self.address)
    }
}

#[async_trait]
pub(super) trait AuthoritativeARecordObserver: Send + Sync {
    async fn discover_endpoints(
        &self,
        zone_name: &str,
    ) -> Result<Vec<AuthoritativeDnsEndpoint>, String>;

    async fn address_present(
        &self,
        endpoint: &AuthoritativeDnsEndpoint,
        record_name: &str,
        address: std::net::Ipv4Addr,
    ) -> Result<bool, String>;
}

struct AuthoritativeDnsObservation {
    endpoint: AuthoritativeDnsEndpoint,
    result: Result<bool, String>,
}

fn all_observations_match(present: bool, observations: &[AuthoritativeDnsObservation]) -> bool {
    !observations.is_empty()
        && observations.iter().all(|observation| {
            observation
                .result
                .as_ref()
                .is_ok_and(|observed| *observed == present)
        })
}

fn visibility_timeout_error(
    name: &str,
    present: bool,
    timeout: Duration,
    stable_polls: usize,
    required_stable_polls: usize,
    observations: &[AuthoritativeDnsObservation],
) -> String {
    let states = observations
        .iter()
        .map(|observation| {
            let state = match &observation.result {
                Ok(true) => "present",
                Ok(false) => "absent",
                Err(_) => "error",
            };
            format!("{}={state}", observation.endpoint.label())
        })
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "authoritative DNS A record {name} did not {} within {} seconds; stable polls {stable_polls}/{required_stable_polls}; last authoritative observations: {states}",
        if present { "appear" } else { "disappear" },
        timeout.as_secs(),
    )
}

fn duration_from_env(name: &str, default: Duration) -> Result<Duration, String> {
    let Ok(value) = std::env::var(name) else {
        return Ok(default);
    };
    let value = value.trim();
    if value.is_empty() {
        return Ok(default);
    }
    let seconds = value
        .parse::<u64>()
        .map_err(|error| format!("parse {name}: {error}"))?;
    if seconds == 0 {
        return Err(format!("{name} must be greater than zero"));
    }
    Ok(Duration::from_secs(seconds))
}

fn positive_usize_from_env(name: &str, default: usize) -> Result<usize, String> {
    let Ok(value) = std::env::var(name) else {
        return Ok(default);
    };
    let value = value.trim();
    if value.is_empty() {
        return Ok(default);
    }
    let parsed = value
        .parse::<usize>()
        .map_err(|error| format!("parse {name}: {error}"))?;
    if parsed == 0 {
        return Err(format!("{name} must be greater than zero"));
    }
    Ok(parsed)
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::net::{Ipv4Addr, SocketAddrV4};
    use std::sync::Mutex;

    use tokio::time::timeout;

    use super::*;

    #[tokio::test(start_paused = true)]
    async fn authoritative_visibility_requires_stable_presence() {
        let observer = Arc::new(SequenceObserver::new([false, true, false, true, true]));
        let visibility = test_visibility(observer);

        timeout(
            Duration::from_secs(20),
            visibility.wait_for("tls.remote.example.com", address(), true),
        )
        .await
        .expect("visibility test timeout")
        .expect("stable authoritative presence");
    }

    #[tokio::test(start_paused = true)]
    async fn authoritative_visibility_requires_stable_absence() {
        let observer = Arc::new(SequenceObserver::new([true, false, true, false, false]));
        let visibility = test_visibility(observer);

        timeout(
            Duration::from_secs(20),
            visibility.wait_for("dns.remote.example.com", address(), false),
        )
        .await
        .expect("visibility test timeout")
        .expect("stable authoritative absence");
    }

    #[tokio::test(start_paused = true)]
    async fn authoritative_visibility_timeout_names_endpoint_without_observer_error() {
        let observer = Arc::new(SequenceObserver::failing("token=visibility-secret"));
        let visibility = AuthoritativeARecordVisibility::new_with_observer(
            "example.com",
            Duration::from_secs(3),
            Duration::from_secs(1),
            2,
            observer,
        );

        let error = visibility
            .wait_for("http.remote.example.com", address(), true)
            .await
            .expect_err("visibility should time out");

        assert!(error.contains("ns1.example.com@192.0.2.53"));
        assert!(error.contains("within 3 seconds"));
        assert!(error.contains("stable polls 0/2"));
        assert!(!error.contains("visibility-secret"));
    }

    fn test_visibility(
        observer: Arc<dyn AuthoritativeARecordObserver>,
    ) -> AuthoritativeARecordVisibility {
        AuthoritativeARecordVisibility::new_with_observer(
            "example.com",
            Duration::from_secs(15),
            Duration::from_secs(1),
            2,
            observer,
        )
    }

    fn address() -> Ipv4Addr {
        Ipv4Addr::new(8, 8, 8, 8)
    }

    struct SequenceObserver {
        states: Mutex<VecDeque<Result<bool, String>>>,
    }

    impl SequenceObserver {
        fn new<const N: usize>(states: [bool; N]) -> Self {
            Self {
                states: Mutex::new(states.into_iter().map(Ok).collect()),
            }
        }

        fn failing(error: &str) -> Self {
            Self {
                states: Mutex::new([Err(error.to_string())].into()),
            }
        }
    }

    #[async_trait]
    impl AuthoritativeARecordObserver for SequenceObserver {
        async fn discover_endpoints(
            &self,
            _zone_name: &str,
        ) -> Result<Vec<AuthoritativeDnsEndpoint>, String> {
            Ok(vec![AuthoritativeDnsEndpoint::new(
                "ns1.example.com",
                IpAddr::V4(*SocketAddrV4::new(Ipv4Addr::new(192, 0, 2, 53), 53).ip()),
            )])
        }

        async fn address_present(
            &self,
            _endpoint: &AuthoritativeDnsEndpoint,
            _record_name: &str,
            _address: Ipv4Addr,
        ) -> Result<bool, String> {
            let mut states = self.states.lock().expect("state lock");
            states
                .pop_front()
                .or_else(|| states.back().cloned())
                .unwrap_or(Ok(false))
        }
    }
}
