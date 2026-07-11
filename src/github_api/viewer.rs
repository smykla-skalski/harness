use std::time::Duration;

use serde::Deserialize;
use serde_json::json;

use crate::errors::{CliError, CliErrorKind};

use super::{GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor};

const VIEWER_LOGIN_QUERY: &str = r"
query HarnessViewerLogin {
  viewer {
    login
  }
}
";

#[derive(Deserialize)]
struct ViewerLoginResponse {
    viewer: ViewerLogin,
}

#[derive(Deserialize)]
struct ViewerLogin {
    login: String,
}

impl GitHubProtectedClient {
    pub(crate) async fn viewer_login(&self) -> Result<String, CliError> {
        let response: ViewerLoginResponse = self
            .graphql(
                GitHubRequestDescriptor::graphql(
                    "github.viewer_login",
                    GitHubPriority::NormalRead,
                    GitHubCachePolicy::read_through(
                        Duration::from_hours(24),
                        Duration::from_hours(24 * 7),
                    ),
                ),
                json!({ "query": VIEWER_LOGIN_QUERY }),
            )
            .await
            .map(|response| response.body)?;
        let login = response.viewer.login.trim();
        if login.is_empty() {
            return Err(CliErrorKind::workflow_io(
                "loading authenticated GitHub viewer returned an empty login",
            )
            .into());
        }
        Ok(login.to_string())
    }
}
