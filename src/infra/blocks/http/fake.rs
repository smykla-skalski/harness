use std::sync::Mutex;
use std::time::Duration;

use crate::infra::blocks::BlockError;

use super::client::HttpClient;
use super::types::{HttpMethod, HttpResponse};

pub struct FakeHttpClient {
    responses: Mutex<Vec<HttpResponse>>,
}

impl FakeHttpClient {
    #[must_use]
    pub fn new(responses: Vec<HttpResponse>) -> Self {
        Self {
            responses: Mutex::new(responses),
        }
    }

    #[must_use]
    pub fn single(status: u16, body: &str) -> Self {
        Self::new(vec![HttpResponse {
            status,
            body: body.to_string(),
        }])
    }
}

impl HttpClient for FakeHttpClient {
    fn request(
        &self,
        _method: HttpMethod,
        _url: &str,
        _body: Option<&serde_json::Value>,
        _headers: &[(&str, &str)],
    ) -> Result<HttpResponse, BlockError> {
        let mut responses = self.responses.lock().expect("lock poisoned");
        assert!(!responses.is_empty(), "FakeHttpClient: no responses left");
        Ok(responses.remove(0))
    }

    fn wait_until_ready(&self, _url: &str, _timeout: Duration) -> Result<(), BlockError> {
        Ok(())
    }
}
