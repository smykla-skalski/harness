use super::*;
use harness::infra::blocks::ReqwestHttpClient;

#[test]
#[ignore] // needs network access
fn production_request_returns_response() {
    contract_request_returns_response(&ReqwestHttpClient::new());
}

#[test]
#[ignore]
fn production_request_json_parses_body() {
    contract_request_json_parses_body(&ReqwestHttpClient::new());
}

#[test]
#[ignore]
fn production_wait_until_ready_times_out() {
    contract_wait_until_ready_times_out_on_unreachable(&ReqwestHttpClient::new());
}
