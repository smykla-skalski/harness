use std::env;
use std::fmt;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use futures_util::future::join_all;
use hickory_resolver::config::{NameServerConfig, ResolverConfig, ResolverOpts};
use hickory_resolver::lookup::Lookup;
use hickory_resolver::net::runtime::TokioRuntimeProvider;
use hickory_resolver::proto::rr::RData;
use hickory_resolver::{Resolver, TokioResolver};
use tokio::time::{Instant, sleep, timeout};

use crate::daemon::remote_redaction::redact_secret_detail;

const TIMEOUT_ENV: &str = "HARNESS_REMOTE_ACME_DNS_VISIBILITY_TIMEOUT_SECONDS";
const POLL_INTERVAL_ENV: &str = "HARNESS_REMOTE_ACME_DNS_VISIBILITY_POLL_SECONDS";
const STABLE_POLLS_ENV: &str = "HARNESS_REMOTE_ACME_DNS_VISIBILITY_STABLE_POLLS";
const DEFAULT_TIMEOUT: Duration = Duration::from_mins(5);
const DEFAULT_POLL_INTERVAL: Duration = Duration::from_secs(5);
const DEFAULT_STABLE_POLLS: usize = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DnsTxtRecordState {
    Present,
    Absent,
}

impl DnsTxtRecordState {
    const fn matches(self, observed: DnsTxtValueState) -> bool {
        match self {
            Self::Present => matches!(observed, DnsTxtValueState::Matching),
            Self::Absent => !matches!(observed, DnsTxtValueState::Matching),
        }
    }

    const fn description(self) -> &'static str {
        match self {
            Self::Present => "appear",
            Self::Absent => "disappear",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DnsTxtValueState {
    Matching,
    Different,
    Absent,
}

impl DnsTxtValueState {
    #[cfg(test)]
    const fn from_present(present: bool) -> Self {
        if present {
            Self::Matching
        } else {
            Self::Absent
        }
    }
}

#[async_trait]
pub(crate) trait DnsTxtVisibilityWaiter: Send + Sync {
    async fn wait_for(
        &self,
        record_name: &str,
        record_value: &str,
        state: DnsTxtRecordState,
    ) -> Result<(), String>;
}

#[derive(Clone)]
pub(crate) struct AuthoritativeDnsTxtVisibilityWaiter {
    zone_name: String,
    timeout: Duration,
    poll_interval: Duration,
    stable_polls: usize,
    observer: Arc<dyn AuthoritativeDnsTxtObserver>,
}

impl fmt::Debug for AuthoritativeDnsTxtVisibilityWaiter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AuthoritativeDnsTxtVisibilityWaiter")
            .field("zone_name", &self.zone_name)
            .field("timeout", &self.timeout)
            .field("poll_interval", &self.poll_interval)
            .field("stable_polls", &self.stable_polls)
            .finish_non_exhaustive()
    }
}

impl AuthoritativeDnsTxtVisibilityWaiter {
    pub(crate) fn from_environment(zone_name: &str) -> Result<Self, String> {
        Ok(Self::new_with_observer(
            zone_name,
            duration_from_env(TIMEOUT_ENV, DEFAULT_TIMEOUT)?,
            duration_from_env(POLL_INTERVAL_ENV, DEFAULT_POLL_INTERVAL)?,
            positive_usize_from_env(STABLE_POLLS_ENV, DEFAULT_STABLE_POLLS)?,
            Arc::new(SystemAuthoritativeDnsTxtObserver),
        ))
    }

    fn new_with_observer(
        zone_name: &str,
        timeout: Duration,
        poll_interval: Duration,
        stable_polls: usize,
        observer: Arc<dyn AuthoritativeDnsTxtObserver>,
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
        record_name: &str,
        record_value: &str,
        query_timeout: Duration,
    ) -> Vec<AuthoritativeDnsObservation> {
        join_all(endpoints.iter().map(|endpoint| async move {
            let result = match timeout(
                query_timeout,
                self.observer
                    .txt_value_state(endpoint, record_name, record_value),
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

#[async_trait]
impl DnsTxtVisibilityWaiter for AuthoritativeDnsTxtVisibilityWaiter {
    async fn wait_for(
        &self,
        record_name: &str,
        record_value: &str,
        state: DnsTxtRecordState,
    ) -> Result<(), String> {
        let endpoints = self.observer.discover_endpoints(&self.zone_name).await?;
        if endpoints.is_empty() {
            return Err(format!(
                "authoritative DNS lookup for {} returned no endpoints",
                self.zone_name
            ));
        }
        let fqdn = format!("{}.", record_name.trim_end_matches('.'));
        let deadline = Instant::now() + self.timeout;
        let mut stable_polls = 0;
        let mut observations = Vec::new();
        loop {
            let now = Instant::now();
            if now >= deadline {
                return Err(visibility_timeout_error(
                    record_name,
                    state,
                    self.timeout,
                    stable_polls,
                    self.stable_polls,
                    &observations,
                ));
            }
            observations = self
                .observe(&endpoints, &fqdn, record_value, deadline - now)
                .await;
            if all_authoritative_observations_match(state, &observations) {
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
                    record_name,
                    state,
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
struct AuthoritativeDnsEndpoint {
    name: String,
    address: IpAddr,
}

impl AuthoritativeDnsEndpoint {
    fn new(name: &str, address: IpAddr) -> Self {
        Self {
            name: name.trim_end_matches('.').to_string(),
            address,
        }
    }

    fn label(&self) -> String {
        format!("{}@{}", self.name, self.address)
    }
}

struct AuthoritativeDnsObservation {
    endpoint: AuthoritativeDnsEndpoint,
    result: Result<DnsTxtValueState, String>,
}

#[async_trait]
trait AuthoritativeDnsTxtObserver: Send + Sync {
    async fn discover_endpoints(
        &self,
        zone_name: &str,
    ) -> Result<Vec<AuthoritativeDnsEndpoint>, String>;

    async fn txt_value_state(
        &self,
        endpoint: &AuthoritativeDnsEndpoint,
        record_name: &str,
        record_value: &str,
    ) -> Result<DnsTxtValueState, String>;
}

struct SystemAuthoritativeDnsTxtObserver;

#[async_trait]
impl AuthoritativeDnsTxtObserver for SystemAuthoritativeDnsTxtObserver {
    async fn discover_endpoints(
        &self,
        zone_name: &str,
    ) -> Result<Vec<AuthoritativeDnsEndpoint>, String> {
        authoritative_endpoints(zone_name).await
    }

    async fn txt_value_state(
        &self,
        endpoint: &AuthoritativeDnsEndpoint,
        record_name: &str,
        record_value: &str,
    ) -> Result<DnsTxtValueState, String> {
        let resolver = build_authoritative_resolver(endpoint)?;
        txt_value_state(&resolver, record_name, record_value).await
    }
}

async fn authoritative_endpoints(zone_name: &str) -> Result<Vec<AuthoritativeDnsEndpoint>, String> {
    let system = TokioResolver::builder_tokio()
        .map_err(|error| format!("load system DNS resolver: {error}"))?
        .build()
        .map_err(|error| format!("build system DNS resolver: {error}"))?;
    let zone_fqdn = format!("{}.", zone_name.trim_end_matches('.'));
    let nameservers = system
        .ns_lookup(&zone_fqdn)
        .await
        .map_err(|error| format!("resolve authoritative DNS servers for {zone_name}: {error}"))?;
    let mut names = nameservers
        .answers()
        .iter()
        .filter_map(|record| match &record.data {
            RData::NS(nameserver) => Some(nameserver.to_string()),
            _ => None,
        })
        .collect::<Vec<_>>();
    names.sort_unstable();
    names.dedup();
    if names.is_empty() {
        return Err(format!(
            "authoritative DNS lookup for {zone_name} returned no nameservers"
        ));
    }
    let mut endpoints = Vec::with_capacity(names.len());
    for nameserver in names {
        let resolved = system
            .lookup_ip(nameserver.as_str())
            .await
            .map_err(|error| format!("resolve authoritative DNS server {nameserver}: {error}"))?;
        let mut addresses = resolved.iter().collect::<Vec<_>>();
        addresses.sort_unstable();
        addresses.dedup();
        if addresses.is_empty() {
            return Err(format!(
                "authoritative DNS server {nameserver} resolved without addresses"
            ));
        }
        endpoints.extend(
            addresses
                .into_iter()
                .map(|address| AuthoritativeDnsEndpoint::new(&nameserver, address)),
        );
    }
    endpoints.sort_unstable();
    endpoints.dedup();
    Ok(endpoints)
}

fn build_authoritative_resolver(
    endpoint: &AuthoritativeDnsEndpoint,
) -> Result<TokioResolver, String> {
    let mut name_server = NameServerConfig::udp_and_tcp(endpoint.address);
    name_server.trust_negative_responses = false;
    let mut options = ResolverOpts::default();
    options.attempts = 2;
    options.cache_size = 0;
    options.num_concurrent_reqs = 1;
    options.recursion_desired = false;
    options.timeout = Duration::from_secs(5);
    options.try_tcp_on_error = true;
    Resolver::builder_with_config(
        ResolverConfig::from_parts(None, Vec::new(), vec![name_server]),
        TokioRuntimeProvider::default(),
    )
    .with_options(options)
    .build()
    .map_err(|error| {
        format!(
            "build authoritative DNS resolver for {}: {error}",
            endpoint.label()
        )
    })
}

async fn txt_value_state(
    resolver: &TokioResolver,
    record_name: &str,
    record_value: &str,
) -> Result<DnsTxtValueState, String> {
    match resolver.txt_lookup(record_name).await {
        Ok(lookup) => Ok(lookup_txt_value_state(&lookup, record_value)),
        Err(error) if error.is_no_records_found() => Ok(DnsTxtValueState::Absent),
        Err(error) => Err(format!(
            "query authoritative TXT record {record_name}: {error}"
        )),
    }
}

fn all_authoritative_observations_match(
    state: DnsTxtRecordState,
    observations: &[AuthoritativeDnsObservation],
) -> bool {
    !observations.is_empty()
        && observations.iter().all(|observation| {
            observation
                .result
                .as_ref()
                .is_ok_and(|observed| state.matches(*observed))
        })
}

#[cfg(test)]
fn all_authoritative_states_match(
    state: DnsTxtRecordState,
    states: impl IntoIterator<Item = bool>,
) -> bool {
    let mut states = states
        .into_iter()
        .map(DnsTxtValueState::from_present)
        .peekable();
    states.peek().is_some() && states.all(|observed| state.matches(observed))
}

fn lookup_contains_txt(lookup: &Lookup, record_value: &str) -> bool {
    lookup.answers().iter().any(|record| {
        let RData::TXT(txt) = &record.data else {
            return false;
        };
        txt.txt_data
            .iter()
            .flat_map(|part| part.iter().copied())
            .eq(record_value.bytes())
    })
}

fn lookup_txt_value_state(lookup: &Lookup, record_value: &str) -> DnsTxtValueState {
    if lookup_contains_txt(lookup, record_value) {
        DnsTxtValueState::Matching
    } else {
        DnsTxtValueState::Different
    }
}

fn duration_from_env(name: &str, default: Duration) -> Result<Duration, String> {
    let Ok(value) = env::var(name) else {
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
    let Ok(value) = env::var(name) else {
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

fn visibility_timeout_error(
    record_name: &str,
    state: DnsTxtRecordState,
    timeout: Duration,
    stable_polls: usize,
    required_stable_polls: usize,
    observations: &[AuthoritativeDnsObservation],
) -> String {
    let endpoint_states = observations
        .iter()
        .map(format_observation)
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "authoritative DNS TXT record {record_name} did not {} within {} seconds; stable polls {stable_polls}/{required_stable_polls}; last authoritative observations: {endpoint_states}",
        state.description(),
        timeout.as_secs(),
    )
}

fn format_observation(observation: &AuthoritativeDnsObservation) -> String {
    let state = match &observation.result {
        Ok(DnsTxtValueState::Matching) => "present".to_string(),
        Ok(DnsTxtValueState::Different) => "different-value".to_string(),
        Ok(DnsTxtValueState::Absent) => "absent".to_string(),
        Err(error) => format!("error({})", redact_secret_detail(error)),
    };
    format!("{}={state}", observation.endpoint.label())
}

#[cfg(test)]
#[path = "remote_acme_dns_visibility_tests.rs"]
mod tests;
