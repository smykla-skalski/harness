use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewsFileCommentKind {
    NewThread,
    Reply,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsFileCommentRequest {
    pub pull_request_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    pub kind: ReviewsFileCommentKind,
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub side: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsFileCommentResponse {
    pub pull_request_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    pub fetched_at: String,
}

impl ReviewsFileCommentRequest {
    pub fn validate(&self) -> Result<(), CliError> {
        if self.pull_request_id.trim().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "review file comment requires a pull request id",
            )
            .into());
        }
        if self.body.trim().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "review file comment requires a non-empty body",
            )
            .into());
        }
        match self.kind {
            ReviewsFileCommentKind::NewThread => self.validate_new_thread(),
            ReviewsFileCommentKind::Reply => self.validate_reply(),
        }
    }

    fn validate_new_thread(&self) -> Result<(), CliError> {
        if self.path.as_deref().unwrap_or_default().trim().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "new review thread requires a file path",
            )
            .into());
        }
        if self.line.unwrap_or_default() == 0 {
            return Err(CliErrorKind::workflow_parse(
                "new review thread requires a one-based line number",
            )
            .into());
        }
        let side = self.side.as_deref().unwrap_or_default();
        if side != "LEFT" && side != "RIGHT" {
            return Err(CliErrorKind::workflow_parse(
                "new review thread requires side LEFT or RIGHT",
            )
            .into());
        }
        Ok(())
    }

    fn validate_reply(&self) -> Result<(), CliError> {
        if self.thread_id.as_deref().unwrap_or_default().trim().is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "review thread reply requires a thread id",
            )
            .into());
        }
        Ok(())
    }

    #[must_use]
    pub fn normalized_body(&self) -> String {
        self.body.trim().to_string()
    }

    #[must_use]
    pub fn response(
        &self,
        thread_id: Option<String>,
        comment_id: Option<String>,
        url: Option<String>,
    ) -> ReviewsFileCommentResponse {
        ReviewsFileCommentResponse {
            pull_request_id: self.pull_request_id.clone(),
            thread_id,
            comment_id,
            url,
            fetched_at: utc_now(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn new_thread_request() -> ReviewsFileCommentRequest {
        ReviewsFileCommentRequest {
            pull_request_id: "PR_kwDOABCD".into(),
            repository: Some("acme/api".into()),
            kind: ReviewsFileCommentKind::NewThread,
            body: "Please check this line".into(),
            path: Some("src/main.rs".into()),
            line: Some(42),
            side: Some("RIGHT".into()),
            thread_id: None,
        }
    }

    #[test]
    fn new_thread_request_requires_path_line_and_side() {
        let mut request = new_thread_request();
        assert!(request.validate().is_ok());

        request.path = Some("  ".into());
        assert!(request.validate().is_err());

        request = new_thread_request();
        request.line = Some(0);
        assert!(request.validate().is_err());

        request = new_thread_request();
        request.side = Some("CENTER".into());
        assert!(request.validate().is_err());
    }

    #[test]
    fn reply_request_requires_thread_id() {
        let mut request = ReviewsFileCommentRequest {
            pull_request_id: "PR_kwDOABCD".into(),
            repository: None,
            kind: ReviewsFileCommentKind::Reply,
            body: "Answered".into(),
            path: None,
            line: None,
            side: None,
            thread_id: None,
        };
        assert!(request.validate().is_err());

        request.thread_id = Some("PRRT_kwDOABCD".into());
        assert!(request.validate().is_ok());
    }
}
