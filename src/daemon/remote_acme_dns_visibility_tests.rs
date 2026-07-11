use std::collections::VecDeque;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use hickory_resolver::lookup::Lookup;
use hickory_resolver::proto::op::Query;
use hickory_resolver::proto::rr::rdata::TXT;
use hickory_resolver::proto::rr::{Name, RData, RecordType};

use super::*;

#[test]
fn visibility_config_uses_provider_neutral_environment() {
    temp_env::with_vars(
        [
            (TIMEOUT_ENV, Some("17")),
            (POLL_INTERVAL_ENV, Some("3")),
            (STABLE_POLLS_ENV, Some("4")),
        ],
        || {
            let waiter = AuthoritativeDnsTxtVisibilityWaiter::from_environment("example.com")
                .expect("visibility config");
            assert_eq!(waiter.timeout, Duration::from_secs(17));
            assert_eq!(waiter.poll_interval, Duration::from_secs(3));
            assert_eq!(waiter.stable_polls, 4);
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
fn visibility_config_rejects_zero_stable_polls() {
    temp_env::with_var(STABLE_POLLS_ENV, Some("0"), || {
        let error = AuthoritativeDnsTxtVisibilityWaiter::from_environment("example.com")
            .expect_err("reject zero stable polls");
        assert_eq!(
            error,
            "HARNESS_REMOTE_ACME_DNS_VISIBILITY_STABLE_POLLS must be greater than zero"
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
    assert_eq!(
        lookup_txt_value_state(&lookup, "dns-proof-value"),
        DnsTxtValueState::Matching
    );
    assert_eq!(
        lookup_txt_value_state(&lookup, "different-value"),
        DnsTxtValueState::Different
    );
}

#[test]
fn visibility_requires_every_authoritative_endpoint_to_match() {
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

#[tokio::test(start_paused = true)]
async fn visibility_requires_consecutive_fresh_present_observations() {
    let observations = [
        true, true, // first matching poll
        true, false, // mismatch resets stability
        true, true, // three fresh matching polls
        true, true, true, true,
    ];
    let (waiter, observer, endpoints) = scripted_waiter(
        observations.map(|present| Ok(DnsTxtValueState::from_present(present))),
        3,
    );

    waiter
        .wait_for(
            "_acme-challenge.example.com",
            "dns-proof-value",
            DnsTxtRecordState::Present,
        )
        .await
        .expect("reach stable authoritative presence");

    assert_eq!(observer.calls(), repeat_endpoints(&endpoints, 5));
}

#[tokio::test(start_paused = true)]
async fn cleanup_waits_past_a_transient_absence_and_resurface() {
    let observations = [
        false, false, // first absent poll
        false, true, // record resurfaces and resets stability
        false, false, // three fresh absent polls
        false, false, false, false,
    ];
    let (waiter, observer, endpoints) = scripted_waiter(
        observations.map(|present| Ok(DnsTxtValueState::from_present(present))),
        3,
    );

    waiter
        .wait_for(
            "_acme-challenge.example.com",
            "dns-proof-value",
            DnsTxtRecordState::Absent,
        )
        .await
        .expect("reach stable authoritative absence");

    assert_eq!(observer.calls(), repeat_endpoints(&endpoints, 5));
}

#[tokio::test(start_paused = true)]
async fn timeout_reports_each_endpoint_state_without_the_txt_value() {
    let observations = [
        Ok(DnsTxtValueState::Matching),
        Err("query refused".to_string()),
        Ok(DnsTxtValueState::Matching),
        Err("query refused".to_string()),
        Ok(DnsTxtValueState::Matching),
        Err("query refused".to_string()),
    ];
    let (waiter, _, _) = scripted_waiter_with_timing(
        observations,
        3,
        Duration::from_secs(2),
        Duration::from_secs(1),
    );

    let error = waiter
        .wait_for(
            "_acme-challenge.example.com",
            "never-log-this-digest",
            DnsTxtRecordState::Present,
        )
        .await
        .expect_err("visibility must time out");

    assert!(error.contains("ns1.example.com@192.0.2.1=present"));
    assert!(error.contains("ns2.example.com@192.0.2.2=error(query refused)"));
    assert!(error.contains("stable polls 0/3"));
    assert!(!error.contains("never-log-this-digest"));
}

#[tokio::test(start_paused = true)]
async fn timeout_distinguishes_a_different_txt_value_from_absence() {
    let observations = [
        Ok(DnsTxtValueState::Matching),
        Ok(DnsTxtValueState::Different),
        Ok(DnsTxtValueState::Matching),
        Ok(DnsTxtValueState::Different),
        Ok(DnsTxtValueState::Matching),
        Ok(DnsTxtValueState::Different),
    ];
    let (waiter, _, _) = scripted_waiter_with_timing(
        observations,
        3,
        Duration::from_secs(2),
        Duration::from_secs(1),
    );

    let error = waiter
        .wait_for(
            "_acme-challenge.example.com",
            "never-log-this-digest",
            DnsTxtRecordState::Present,
        )
        .await
        .expect_err("visibility must time out");

    assert!(error.contains("ns1.example.com@192.0.2.1=present"));
    assert!(error.contains("ns2.example.com@192.0.2.2=different-value"));
    assert!(!error.contains("never-log-this-digest"));
}

fn scripted_waiter<const N: usize>(
    observations: [Result<DnsTxtValueState, String>; N],
    stable_polls: usize,
) -> (
    AuthoritativeDnsTxtVisibilityWaiter,
    ScriptedDnsTxtObserver,
    Vec<AuthoritativeDnsEndpoint>,
) {
    scripted_waiter_with_timing(
        observations,
        stable_polls,
        Duration::from_secs(30),
        Duration::from_secs(1),
    )
}

fn scripted_waiter_with_timing<const N: usize>(
    observations: [Result<DnsTxtValueState, String>; N],
    stable_polls: usize,
    timeout: Duration,
    poll_interval: Duration,
) -> (
    AuthoritativeDnsTxtVisibilityWaiter,
    ScriptedDnsTxtObserver,
    Vec<AuthoritativeDnsEndpoint>,
) {
    let endpoints = vec![
        AuthoritativeDnsEndpoint::new("ns1.example.com", IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1))),
        AuthoritativeDnsEndpoint::new("ns2.example.com", IpAddr::V4(Ipv4Addr::new(192, 0, 2, 2))),
    ];
    let observer = ScriptedDnsTxtObserver::new(endpoints.clone(), observations);
    let waiter = AuthoritativeDnsTxtVisibilityWaiter::new_with_observer(
        "example.com",
        timeout,
        poll_interval,
        stable_polls,
        Arc::new(observer.clone()),
    );
    (waiter, observer, endpoints)
}

fn repeat_endpoints(
    endpoints: &[AuthoritativeDnsEndpoint],
    count: usize,
) -> Vec<AuthoritativeDnsEndpoint> {
    (0..count).flat_map(|_| endpoints.iter().cloned()).collect()
}

#[derive(Clone)]
struct ScriptedDnsTxtObserver {
    inner: Arc<Mutex<ScriptedDnsTxtObserverState>>,
}

struct ScriptedDnsTxtObserverState {
    endpoints: Vec<AuthoritativeDnsEndpoint>,
    observations: VecDeque<Result<DnsTxtValueState, String>>,
    calls: Vec<AuthoritativeDnsEndpoint>,
}

impl ScriptedDnsTxtObserver {
    fn new<const N: usize>(
        endpoints: Vec<AuthoritativeDnsEndpoint>,
        observations: [Result<DnsTxtValueState, String>; N],
    ) -> Self {
        Self {
            inner: Arc::new(Mutex::new(ScriptedDnsTxtObserverState {
                endpoints,
                observations: observations.into(),
                calls: Vec::new(),
            })),
        }
    }

    fn calls(&self) -> Vec<AuthoritativeDnsEndpoint> {
        self.inner.lock().expect("lock observer").calls.clone()
    }
}

#[async_trait]
impl AuthoritativeDnsTxtObserver for ScriptedDnsTxtObserver {
    async fn discover_endpoints(
        &self,
        _zone_name: &str,
    ) -> Result<Vec<AuthoritativeDnsEndpoint>, String> {
        Ok(self
            .inner
            .lock()
            .map_err(|error| error.to_string())?
            .endpoints
            .clone())
    }

    async fn txt_value_state(
        &self,
        endpoint: &AuthoritativeDnsEndpoint,
        _record_name: &str,
        _record_value: &str,
    ) -> Result<DnsTxtValueState, String> {
        let mut state = self.inner.lock().map_err(|error| error.to_string())?;
        state.calls.push(endpoint.clone());
        state
            .observations
            .pop_front()
            .ok_or_else(|| "scripted DNS observation exhausted".to_string())?
    }
}
