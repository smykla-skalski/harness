use std::env;
use std::net::IpAddr;
use std::time::Duration;

use async_trait::async_trait;
use hickory_resolver::config::{NameServerConfig, ResolverConfig, ResolverOpts};
use hickory_resolver::lookup::Lookup;
use hickory_resolver::net::runtime::TokioRuntimeProvider;
use hickory_resolver::proto::rr::{RData, RecordType};
use hickory_resolver::{Resolver, TokioResolver};
use tokio::time::{Instant, sleep};

const TIMEOUT_ENV: &str = "HARNESS_REMOTE_ACME_DNS_VISIBILITY_TIMEOUT_SECONDS";
const POLL_INTERVAL_ENV: &str = "HARNESS_REMOTE_ACME_DNS_VISIBILITY_POLL_SECONDS";
const DEFAULT_TIMEOUT: Duration = Duration::from_mins(5);
const DEFAULT_POLL_INTERVAL: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DnsTxtRecordState {
    Present,
    Absent,
}

impl DnsTxtRecordState {
    const fn matches(self, present: bool) -> bool {
        match self {
            Self::Present => present,
            Self::Absent => !present,
        }
    }

    const fn description(self) -> &'static str {
        match self {
            Self::Present => "appear",
            Self::Absent => "disappear",
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

#[derive(Debug, Clone)]
pub(crate) struct AuthoritativeDnsTxtVisibilityWaiter {
    zone_name: String,
    timeout: Duration,
    poll_interval: Duration,
}

impl AuthoritativeDnsTxtVisibilityWaiter {
    pub(crate) fn from_environment(zone_name: &str) -> Result<Self, String> {
        Ok(Self {
            zone_name: zone_name.to_string(),
            timeout: duration_from_env(TIMEOUT_ENV, DEFAULT_TIMEOUT)?,
            poll_interval: duration_from_env(POLL_INTERVAL_ENV, DEFAULT_POLL_INTERVAL)?,
        })
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
        let resolvers = authoritative_resolvers(&self.zone_name).await?;
        let fqdn = format!("{}.", record_name.trim_end_matches('.'));
        let deadline = Instant::now() + self.timeout;
        loop {
            let query_error =
                match all_authoritative_resolvers_match(&resolvers, &fqdn, record_value, state)
                    .await
                {
                    Ok(true) => return Ok(()),
                    Ok(_) => None,
                    Err(error) => Some(error),
                };
            let now = Instant::now();
            if now >= deadline {
                return Err(visibility_timeout_error(
                    record_name,
                    state,
                    self.timeout,
                    query_error.as_deref(),
                ));
            }
            sleep(self.poll_interval.min(deadline - now)).await;
        }
    }
}

struct AuthoritativeDnsResolver {
    name: String,
    resolver: TokioResolver,
}

async fn authoritative_resolvers(zone_name: &str) -> Result<Vec<AuthoritativeDnsResolver>, String> {
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
    let mut resolvers = Vec::with_capacity(names.len());
    for nameserver in names {
        let resolved = system
            .lookup_ip(nameserver.as_str())
            .await
            .map_err(|error| format!("resolve authoritative DNS server {nameserver}: {error}"))?;
        let mut addresses = resolved.iter().collect::<Vec<_>>();
        addresses.sort_unstable();
        addresses.dedup();
        resolvers.push(AuthoritativeDnsResolver {
            resolver: build_authoritative_resolver(&addresses, &nameserver)?,
            name: nameserver,
        });
    }
    Ok(resolvers)
}

fn build_authoritative_resolver(
    addresses: &[IpAddr],
    zone_name: &str,
) -> Result<TokioResolver, String> {
    if addresses.is_empty() {
        return Err(format!(
            "authoritative DNS servers for {zone_name} resolved without addresses"
        ));
    }
    let name_servers = addresses
        .iter()
        .copied()
        .map(|address| {
            let mut config = NameServerConfig::udp_and_tcp(address);
            config.trust_negative_responses = false;
            config
        })
        .collect();
    let mut options = ResolverOpts::default();
    options.attempts = 2;
    options.cache_size = 0;
    options.num_concurrent_reqs = addresses.len().min(2);
    options.recursion_desired = false;
    options.timeout = Duration::from_secs(5);
    options.try_tcp_on_error = true;
    Resolver::builder_with_config(
        ResolverConfig::from_parts(None, Vec::new(), name_servers),
        TokioRuntimeProvider::default(),
    )
    .with_options(options)
    .build()
    .map_err(|error| format!("build authoritative DNS resolver for {zone_name}: {error}"))
}

async fn txt_value_present(
    resolver: &TokioResolver,
    record_name: &str,
    record_value: &str,
) -> Result<bool, String> {
    match resolver.txt_lookup(record_name).await {
        Ok(lookup) => Ok(lookup_contains_txt(&lookup, record_value)),
        Err(error) if error.is_no_records_found() => Ok(false),
        Err(error) => Err(format!(
            "query authoritative TXT record {record_name}: {error}"
        )),
    }
}

async fn all_authoritative_resolvers_match(
    resolvers: &[AuthoritativeDnsResolver],
    record_name: &str,
    record_value: &str,
    state: DnsTxtRecordState,
) -> Result<bool, String> {
    let mut states = Vec::with_capacity(resolvers.len());
    for server in resolvers {
        server
            .resolver
            .clear_lookup_cache(record_name, RecordType::TXT);
        states.push(
            txt_value_present(&server.resolver, record_name, record_value)
                .await
                .map_err(|error| format!("{error} via {}", server.name))?,
        );
    }
    Ok(all_authoritative_states_match(state, states))
}

fn all_authoritative_states_match(
    state: DnsTxtRecordState,
    states: impl IntoIterator<Item = bool>,
) -> bool {
    let mut states = states.into_iter().peekable();
    states.peek().is_some() && states.all(|present| state.matches(present))
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

fn visibility_timeout_error(
    record_name: &str,
    state: DnsTxtRecordState,
    timeout: Duration,
    last_error: Option<&str>,
) -> String {
    let detail = last_error.map_or_else(String::new, |error| format!("; last query: {error}"));
    format!(
        "authoritative DNS TXT record {record_name} did not {} within {} seconds{detail}",
        state.description(),
        timeout.as_secs(),
    )
}

#[cfg(test)]
mod tests {
    use hickory_resolver::lookup::Lookup;
    use hickory_resolver::proto::op::Query;
    use hickory_resolver::proto::rr::rdata::TXT;
    use hickory_resolver::proto::rr::{Name, RData, RecordType};

    use super::*;

    #[test]
    fn visibility_config_uses_provider_neutral_environment() {
        temp_env::with_vars(
            [(TIMEOUT_ENV, Some("17")), (POLL_INTERVAL_ENV, Some("3"))],
            || {
                let waiter = AuthoritativeDnsTxtVisibilityWaiter::from_environment("example.com")
                    .expect("visibility config");
                assert_eq!(waiter.timeout, Duration::from_secs(17));
                assert_eq!(waiter.poll_interval, Duration::from_secs(3));
            },
        );
    }

    #[test]
    fn visibility_config_rejects_zero_duration() {
        temp_env::with_var(TIMEOUT_ENV, Some("0"), || {
            let error = AuthoritativeDnsTxtVisibilityWaiter::from_environment("example.com")
                .expect_err("reject zero timeout");
            assert_eq!(
                error,
                "HARNESS_REMOTE_ACME_DNS_VISIBILITY_TIMEOUT_SECONDS must be greater than zero"
            );
        });
    }

    #[test]
    fn txt_matching_joins_segments_and_requires_the_exact_value() {
        let query = Query::query(
            Name::from_ascii("_acme-challenge.example.com.").expect("record name"),
            RecordType::TXT,
        );
        let lookup = Lookup::from_rdata(
            query,
            RData::TXT(TXT::from_bytes(vec![b"dns-proof-", b"value"])),
        );

        assert!(lookup_contains_txt(&lookup, "dns-proof-value"));
        assert!(!lookup_contains_txt(&lookup, "dns-proof"));
    }

    #[test]
    fn visibility_requires_every_authoritative_server_to_match() {
        assert!(all_authoritative_states_match(
            DnsTxtRecordState::Present,
            [true, true]
        ));
        assert!(!all_authoritative_states_match(
            DnsTxtRecordState::Present,
            [true, false]
        ));
        assert!(all_authoritative_states_match(
            DnsTxtRecordState::Absent,
            [false, false]
        ));
        assert!(!all_authoritative_states_match(
            DnsTxtRecordState::Absent,
            [false, true]
        ));
    }
}
