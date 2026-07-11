use std::net::{IpAddr, Ipv4Addr};
use std::time::Duration;

use async_trait::async_trait;
use hickory_resolver::config::{NameServerConfig, ResolverConfig, ResolverOpts};
use hickory_resolver::net::runtime::TokioRuntimeProvider;
use hickory_resolver::proto::rr::RData;
use hickory_resolver::{Resolver, TokioResolver};

use super::visibility::{AuthoritativeARecordObserver, AuthoritativeDnsEndpoint};

pub(super) struct SystemAuthoritativeARecordObserver;

#[async_trait]
impl AuthoritativeARecordObserver for SystemAuthoritativeARecordObserver {
    async fn discover_endpoints(
        &self,
        zone_name: &str,
    ) -> Result<Vec<AuthoritativeDnsEndpoint>, String> {
        authoritative_endpoints(zone_name).await
    }

    async fn address_present(
        &self,
        endpoint: &AuthoritativeDnsEndpoint,
        record_name: &str,
        address: Ipv4Addr,
    ) -> Result<bool, String> {
        let resolver = build_authoritative_resolver(endpoint)?;
        match resolver.lookup_ip(record_name).await {
            Ok(lookup) => Ok(lookup
                .iter()
                .any(|observed| observed == IpAddr::V4(address))),
            Err(error) if error.is_no_records_found() => Ok(false),
            Err(error) => Err(format!(
                "query authoritative A record {record_name}: {error}"
            )),
        }
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
