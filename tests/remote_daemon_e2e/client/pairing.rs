use reqwest::StatusCode;
use serde_json::{Value, json};

use super::{RemoteCredentials, RemoteDaemonClient, required_string};

impl RemoteDaemonClient {
    pub async fn claim_pairing(
        &self,
        code: &str,
        client_id: &str,
        role: &str,
    ) -> Result<RemoteCredentials, String> {
        let response = self
            .http
            .post(self.url("/v1/remote/pair/claim"))
            .json(&json!({
                "code": code,
                "domain": self.domain,
                "client_id": client_id,
                "display_name": format!("Remote E2E {role}"),
                "platform": "e2e",
            }))
            .send()
            .await
            .map_err(|error| format!("claim remote pairing: {error}"))?;
        let status = response.status();
        let body = response
            .json::<Value>()
            .await
            .map_err(|error| format!("decode pairing response: {error}"))?;
        if !status.is_success() {
            return Err(format!("pairing claim returned {status}: {body}"));
        }
        Ok(RemoteCredentials {
            client_id: required_string(&body, "client_id")?.to_string(),
            token: required_string(&body, "token")?.to_string(),
            role: required_string(&body, "role")?.to_string(),
        })
    }

    pub async fn expect_pairing_status(
        &self,
        pairing_id: &str,
        expected: &str,
    ) -> Result<(), String> {
        let response = self
            .http
            .post(self.url("/v1/remote/pair/status"))
            .json(&json!({ "pairing_id": pairing_id }))
            .send()
            .await
            .map_err(|error| format!("load remote pairing status: {error}"))?;
        let status = response.status();
        let body = response
            .json::<Value>()
            .await
            .map_err(|error| format!("decode remote pairing status: {error}"))?;
        if status != StatusCode::OK || body != json!({ "status": expected }) {
            return Err(format!(
                "remote pairing status mismatch: expected {expected}, received {status} {body}"
            ));
        }
        Ok(())
    }
}
