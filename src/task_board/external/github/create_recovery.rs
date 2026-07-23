use std::collections::HashSet;

use async_trait::async_trait;
use reqwest::header::{HeaderMap, LINK};
use reqwest::{Method, Url};
use serde::Deserialize;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubRequestDescriptor, retry_stable_read,
};
use crate::task_board::normalize_repository_slug;

use super::super::{
    ExternalCreateLease, ExternalCreateProbe, ExternalCreateRecoveryClient, ExternalCreateRequest,
    ExternalProvider, ExternalTask,
};
use super::create_marker::{extract_from_body, render_body};
use super::write::GitHubIssueResponse;
use super::{GitHubRepository, GitHubSyncClient, parse_github_repository};

const PAGE_SIZE: usize = 100;
const MAX_SCAN_PAGES: u32 = 10_000;

#[async_trait]
impl ExternalCreateRecoveryClient for GitHubSyncClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn supports_target(&self, provider_target: &str) -> bool {
        let Some(normalized) = normalize_repository_slug(Some(provider_target)) else {
            return false;
        };
        if normalized != provider_target {
            return false;
        }
        self.repository.as_ref().is_none_or(|configured| {
            normalize_repository_slug(Some(&configured.slug())).as_deref() == Some(&normalized)
        })
    }

    async fn create_started(
        &self,
        request: &ExternalCreateRequest,
        lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalTask, CliError> {
        let repository = self.recovery_repository(request.provider_target())?;
        let marked_body = render_body(request.body(), request.create_key())?;
        lease.renew().await?;
        match self
            .create_issue_fields(&repository, request.title(), Some(&marked_body))
            .await
        {
            Ok(issue) => exact_created_task(issue, &repository, request.create_key()),
            Err(create_error) => {
                match self
                    .scan_create_marker(&repository, request.create_key(), lease)
                    .await
                {
                    Ok(RecoveryScanCompletion::Probe(ExternalCreateProbe::Found(task))) => {
                        Ok(*task)
                    }
                    Ok(RecoveryScanCompletion::Probe(ExternalCreateProbe::Absent)) => {
                        Err(create_error)
                    }
                    Ok(RecoveryScanCompletion::DuplicateMatches) => {
                        Err(duplicate_match_error(request.create_key()))
                    }
                    Err(scan_error) => {
                        Err(combine_create_and_scan_errors(create_error, &scan_error))
                    }
                }
            }
        }
    }

    async fn recover_existing(
        &self,
        request: &ExternalCreateRequest,
        lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalCreateProbe, CliError> {
        let repository = self.recovery_repository(request.provider_target())?;
        let completion = self
            .scan_create_marker(&repository, request.create_key(), lease)
            .await?;
        match completion {
            RecoveryScanCompletion::Probe(found @ ExternalCreateProbe::Found(_)) => Ok(found),
            RecoveryScanCompletion::Probe(ExternalCreateProbe::Absent) => {
                Err(CliErrorKind::workflow_io(format!(
                    "task-board github create recovery found no issue in {}; refusing to create again",
                    repository.slug()
                ))
                .into())
            }
            RecoveryScanCompletion::DuplicateMatches => {
                Err(duplicate_match_error(request.create_key()))
            }
        }
    }

    fn extract_create_key(&self, task: &mut ExternalTask) -> Result<Option<String>, CliError> {
        extract_from_body(&mut task.body)
    }
}

impl GitHubSyncClient {
    fn recovery_repository(&self, provider_target: &str) -> Result<GitHubRepository, CliError> {
        if !ExternalCreateRecoveryClient::supports_target(self, provider_target) {
            return Err(CliErrorKind::workflow_io(format!(
                "task-board github create recovery does not support target '{provider_target}'"
            ))
            .into());
        }
        parse_github_repository(provider_target)
    }

    async fn scan_create_marker(
        &self,
        repository: &GitHubRepository,
        create_key: &str,
        lease: &dyn ExternalCreateLease,
    ) -> Result<RecoveryScanCompletion, CliError> {
        retry_stable_read("task_board.github.create_recovery", |_| {
            self.scan_create_marker_once(repository, create_key, lease)
        })
        .await
        .map(|(probe, _)| probe)
    }

    async fn scan_create_marker_once(
        &self,
        repository: &GitHubRepository,
        create_key: &str,
        lease: &dyn ExternalCreateLease,
    ) -> Result<RecoveryScanCompletion, CliError> {
        let mut state = RecoveryScanState::default();
        loop {
            state.visit_page()?;
            lease.renew().await?;
            let route = recovery_route(repository, state.page);
            let response = self
                .protected()
                .rest_json_with_headers::<Vec<GitHubRecoveryIssue>>(
                    Method::GET,
                    route,
                    None,
                    recovery_read_descriptor(),
                    HeaderMap::new(),
                )
                .await?;
            let issues = response.body.ok_or_else(|| {
                CliErrorKind::workflow_io(
                    "task-board github create recovery page returned no response body",
                )
            })?;
            let next = validate_link_headers(&response.headers, state.page)?;
            if issues.is_empty() {
                if next.is_some() {
                    return Err(scan_error(
                        "empty terminal page unexpectedly advertised rel=next",
                    ));
                }
                return Ok(state.finish());
            }
            if issues.len() > PAGE_SIZE {
                return Err(scan_error(format!(
                    "page {} exceeded the requested {PAGE_SIZE} rows",
                    state.page
                )));
            }
            for issue in issues {
                state.observe_issue(issue, repository, create_key)?;
            }
            state.advance(next)?;
        }
    }
}

#[derive(Deserialize)]
struct GitHubRecoveryIssue {
    #[serde(flatten)]
    issue: GitHubIssueResponse,
    #[serde(default)]
    pull_request: Option<serde_json::Value>,
}

#[derive(Default)]
struct RecoveryScanState {
    page: u32,
    seen_pages: HashSet<u32>,
    seen_issue_numbers: HashSet<u64>,
    found: Option<ExternalTask>,
    duplicate_match: bool,
}

impl RecoveryScanState {
    fn visit_page(&mut self) -> Result<(), CliError> {
        if self.page == 0 {
            self.page = 1;
        }
        if self.page > MAX_SCAN_PAGES {
            return Err(scan_error(format!(
                "exceeded the {MAX_SCAN_PAGES}-page safety cap"
            )));
        }
        if !self.seen_pages.insert(self.page) {
            return Err(scan_error(format!("repeated page {}", self.page)));
        }
        Ok(())
    }

    fn observe_issue(
        &mut self,
        issue: GitHubRecoveryIssue,
        repository: &GitHubRepository,
        create_key: &str,
    ) -> Result<(), CliError> {
        let number = issue.issue.number;
        if !self.seen_issue_numbers.insert(number) {
            return Err(CliErrorKind::concurrent_modification(format!(
                "task-board github create recovery repeated raw issue number {number}"
            ))
            .into());
        }
        if issue.pull_request.is_some() {
            return Ok(());
        }
        let mut task = issue.issue.into_external_task(repository);
        if extract_from_body(&mut task.body)?.as_deref() != Some(create_key) {
            return Ok(());
        }
        if self.found.is_some() {
            self.duplicate_match = true;
        } else {
            self.found = Some(task);
        }
        Ok(())
    }

    fn advance(&mut self, linked_next: Option<u32>) -> Result<(), CliError> {
        let expected = self
            .page
            .checked_add(1)
            .ok_or_else(|| scan_error("page number overflow"))?;
        if expected > MAX_SCAN_PAGES {
            return Err(scan_error(format!(
                "reached the {MAX_SCAN_PAGES}-page safety cap before an empty terminal page"
            )));
        }
        if let Some(linked_next) = linked_next
            && linked_next != expected
        {
            return Err(scan_error(format!(
                "rel=next page {linked_next} did not equal sequential page {expected}"
            )));
        }
        self.page = expected;
        Ok(())
    }

    fn finish(self) -> RecoveryScanCompletion {
        if self.duplicate_match {
            return RecoveryScanCompletion::DuplicateMatches;
        }
        RecoveryScanCompletion::Probe(self.found.map_or(ExternalCreateProbe::Absent, |task| {
            ExternalCreateProbe::Found(Box::new(task))
        }))
    }
}

enum RecoveryScanCompletion {
    Probe(ExternalCreateProbe),
    DuplicateMatches,
}

fn exact_created_task(
    issue: GitHubIssueResponse,
    repository: &GitHubRepository,
    expected_key: &str,
) -> Result<ExternalTask, CliError> {
    let mut task = issue.into_external_task(repository);
    let actual_key = extract_from_body(&mut task.body)?;
    if actual_key.as_deref() != Some(expected_key) {
        return Err(CliErrorKind::workflow_parse(
            "task-board github created issue response did not contain the persisted create marker",
        )
        .into());
    }
    Ok(task)
}

fn recovery_route(repository: &GitHubRepository, page: u32) -> String {
    format!(
        "/repos/{}/{}/issues?filter=all&state=all&sort=created&direction=asc&per_page={PAGE_SIZE}&page={page}",
        repository.owner, repository.repo
    )
}

fn recovery_read_descriptor() -> GitHubRequestDescriptor {
    GitHubRequestDescriptor::rest_core(
        "task_board.github.create_recovery_page",
        GitHubPriority::FreshRead,
        GitHubCachePolicy::no_store(),
    )
}

fn validate_link_headers(headers: &HeaderMap, current_page: u32) -> Result<Option<u32>, CliError> {
    let mut next_page = None;
    for value in headers.get_all(LINK) {
        let value = value
            .to_str()
            .map_err(|error| scan_error(format!("Link header is not UTF-8: {error}")))?;
        for entry in value.split(',') {
            let parsed = parse_link_entry(entry.trim())?;
            if parsed
                .relations
                .iter()
                .any(|relation| relation.eq_ignore_ascii_case("next"))
                && next_page.replace(parsed.page).is_some()
            {
                return Err(scan_error("duplicate rel=next Link entries"));
            }
        }
    }
    if let Some(next_page) = next_page {
        let expected = current_page
            .checked_add(1)
            .ok_or_else(|| scan_error("page number overflow"))?;
        if next_page <= current_page || next_page != expected {
            return Err(scan_error(format!(
                "rel=next page {next_page} did not equal sequential page {expected}"
            )));
        }
    }
    Ok(next_page)
}

struct ParsedLink {
    page: u32,
    relations: Vec<String>,
}

fn parse_link_entry(entry: &str) -> Result<ParsedLink, CliError> {
    if entry.is_empty() {
        return Err(scan_error("Link header contained an empty entry"));
    }
    let (target, parameters) = entry
        .strip_prefix('<')
        .and_then(|value| value.split_once('>'))
        .ok_or_else(|| scan_error("Link entry must contain an angle-bracketed URL"))?;
    if !parameters.starts_with(';') {
        return Err(scan_error("Link entry URL must be followed by parameters"));
    }
    let url = Url::parse(target)
        .map_err(|error| scan_error(format!("Link entry URL is invalid: {error}")))?;
    validate_link_url(&url)?;
    let relations = parse_link_relations(parameters)?;
    let page = parse_link_page(&url)?;
    Ok(ParsedLink { page, relations })
}

fn parse_link_relations(parameters: &str) -> Result<Vec<String>, CliError> {
    let mut relations = None;
    for parameter in parameters.split(';').skip(1) {
        let (name, value) = parameter
            .trim()
            .split_once('=')
            .ok_or_else(|| scan_error("Link parameter must use name=value syntax"))?;
        let name = name.trim();
        let value = value.trim();
        if !valid_link_token(name) || value.is_empty() {
            return Err(scan_error(
                "Link parameter name must be a token and value must be nonempty",
            ));
        }
        if name.eq_ignore_ascii_case("rel") {
            if relations.is_some() {
                return Err(scan_error("Link entry contained duplicate rel parameters"));
            }
            let value = value
                .strip_prefix('"')
                .and_then(|value| value.strip_suffix('"'))
                .ok_or_else(|| scan_error("Link rel value must be quoted"))?;
            let parsed = value
                .split_ascii_whitespace()
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>();
            if parsed.is_empty() {
                return Err(scan_error("Link rel value must be nonempty"));
            }
            if parsed.iter().any(|relation| !valid_link_token(relation)) {
                return Err(scan_error("Link rel value contained an invalid token"));
            }
            if parsed
                .iter()
                .filter(|relation| relation.eq_ignore_ascii_case("next"))
                .count()
                > 1
            {
                return Err(scan_error("Link entry contained duplicate next relations"));
            }
            relations = Some(parsed);
        } else {
            return Err(scan_error(format!(
                "Link entry contained unsupported parameter '{name}'"
            )));
        }
    }
    relations.ok_or_else(|| scan_error("Link entry is missing a rel parameter"))
}

fn valid_link_token(value: &str) -> bool {
    !value.is_empty()
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || matches!(
                    byte,
                    b'!' | b'#'
                        | b'$'
                        | b'%'
                        | b'&'
                        | b'\''
                        | b'*'
                        | b'+'
                        | b'-'
                        | b'.'
                        | b'^'
                        | b'_'
                        | b'`'
                        | b'|'
                        | b'~'
                )
        })
}

fn validate_link_url(url: &Url) -> Result<(), CliError> {
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return Err(scan_error("Link target must be an absolute HTTP URL"));
    }
    if !url.username().is_empty() || url.password().is_some() || url.fragment().is_some() {
        return Err(scan_error(
            "Link target must not contain credentials or a fragment",
        ));
    }
    Ok(())
}

fn parse_link_page(url: &Url) -> Result<u32, CliError> {
    let mut page = None;
    for (name, value) in url.query_pairs() {
        if name == "page" {
            if page.is_some() {
                return Err(scan_error(
                    "Link target contained a duplicate page parameter",
                ));
            }
            page = Some(value.into_owned());
        }
    }
    let page = page
        .as_deref()
        .ok_or_else(|| scan_error("Link target is missing the page parameter"))?;
    let parsed = page
        .parse::<u32>()
        .map_err(|error| scan_error(format!("Link page is invalid: {error}")))?;
    let canonical = parsed.to_string();
    if parsed == 0 || page != canonical.as_str() {
        return Err(scan_error("Link page is not a canonical positive integer"));
    }
    Ok(parsed)
}

fn combine_create_and_scan_errors(create_error: CliError, scan_error: &CliError) -> CliError {
    let scan_details = error_with_details(scan_error);
    let combined = format!("provider recovery scan also failed with {scan_details}");
    let details = create_error.details().map_or_else(
        || combined.clone(),
        |details| format!("{details}; {combined}"),
    );
    create_error.with_details(details)
}

fn duplicate_match_error(create_key: &str) -> CliError {
    CliErrorKind::concurrent_modification(format!(
        "task-board github create recovery found multiple issues for create key '{create_key}'"
    ))
    .into()
}

fn error_with_details(error: &CliError) -> String {
    error.details().map_or_else(
        || error.to_string(),
        |details| format!("{error}; {details}"),
    )
}

fn scan_error(detail: impl Into<String>) -> CliError {
    CliErrorKind::workflow_io(format!(
        "task-board github create recovery scan was incomplete: {}",
        detail.into()
    ))
    .into()
}

#[cfg(test)]
mod tests;
