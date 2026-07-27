//! Session-id resolution shared by every binary that carries a `HookAgent`.
//!
//! The root crate and `harness-hook` each kept a hand-duplicated copy of this
//! bookkeeping. Their storage layers and default-session-id fallbacks stay
//! genuinely different per binary: both mint a timestamped default, but pick
//! its agent-name prefix differently (root hardcodes a per-agent match,
//! `harness-hook` derives it from the adapter name), so they are passed in
//! as closures rather than duplicated here.

use std::env;
use std::path::{Path, PathBuf};

use harness_kernel::errors::CliError;

use crate::agent::HookAgent;

/// Read an environment variable, treating a blank value the same as unset.
#[must_use]
pub fn trimmed_env(key: &str) -> Option<String> {
    env::var(key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

/// Read the runtime-reported session id from the agent's own environment
/// variables, in priority order.
#[must_use]
pub fn session_id_from_env(agent: HookAgent) -> Option<String> {
    let candidates = match agent {
        HookAgent::Claude => &["CLAUDE_SESSION_ID"][..],
        HookAgent::Codex => &["CODEX_SESSION_ID", "CODEX_THREAD_ID"][..],
        HookAgent::Gemini => &["GEMINI_SESSION_ID", "CLAUDE_SESSION_ID"][..],
        HookAgent::Copilot => &["COPILOT_SESSION_ID"][..],
        HookAgent::Vibe => &["VIBE_SESSION_ID"][..],
        HookAgent::OpenCode => &["OPENCODE_SESSION_ID"][..],
    };
    candidates
        .iter()
        .find_map(|name| env::var(name).ok().filter(|value| !value.trim().is_empty()))
}

/// Resolve a hook context's working directory, unescaping a shell-escaped
/// path when the literal path does not exist.
#[must_use]
pub fn resolve_context_cwd(path: &Path) -> Option<PathBuf> {
    if path.is_dir() {
        return Some(path.to_path_buf());
    }
    shell_unescaped_path(path).filter(|candidate| candidate.is_dir())
}

/// Undo shell backslash-escaping, for example turning `project\@team` back
/// into `project@team`. Leaves `\\` and `\/` untouched, since those are
/// themselves valid escape sequences rather than characters shell-escaped by
/// mistake. Returns `None` when nothing needed unescaping.
#[must_use]
pub fn shell_unescaped_path(path: &Path) -> Option<PathBuf> {
    let raw = path.to_str()?;
    let mut changed = false;
    let mut unescaped = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '\\'
            && let Some(next) = chars.peek().copied()
            && next != '\\'
            && next != '/'
        {
            unescaped.push(next);
            let _ = chars.next();
            changed = true;
            continue;
        }
        unescaped.push(character);
    }
    changed.then(|| PathBuf::from(unescaped))
}

/// Resolve a known session id for a hook or lifecycle event: an explicit
/// hint wins, then the agent's own environment, then whatever
/// `lookup_stored` reports from the binary's own storage layer.
///
/// # Errors
/// Propagates any error `lookup_stored` returns.
pub fn resolve_known_session_id(
    agent: HookAgent,
    session_id_hint: Option<&str>,
    lookup_stored: impl FnOnce() -> Result<Option<String>, CliError>,
) -> Result<Option<String>, CliError> {
    if let Some(session_id) = session_id_hint.filter(|value| !value.trim().is_empty()) {
        return Ok(Some(session_id.to_string()));
    }
    if let Some(session_id) = session_id_from_env(agent) {
        return Ok(Some(session_id));
    }
    lookup_stored()
}

/// Resolve the effective session id for a hook or lifecycle event, minting
/// one through `default_session_id` when nothing existing can be found.
///
/// # Errors
/// Propagates any error `lookup_stored` returns.
pub fn resolve_or_create_session_id(
    agent: HookAgent,
    session_id_hint: Option<&str>,
    lookup_stored: impl FnOnce() -> Result<Option<String>, CliError>,
    default_session_id: impl FnOnce(HookAgent) -> String,
) -> Result<String, CliError> {
    Ok(
        resolve_known_session_id(agent, session_id_hint, lookup_stored)?
            .unwrap_or_else(|| default_session_id(agent)),
    )
}

#[cfg(test)]
mod tests {
    use std::env;

    use super::{
        HookAgent, resolve_context_cwd, resolve_known_session_id, resolve_or_create_session_id,
        session_id_from_env, shell_unescaped_path, trimmed_env,
    };

    #[test]
    fn trimmed_env_rejects_blank_and_unset() {
        let key = "HARNESS_TEST_TRIMMED_ENV_ROUNDTRIP";
        temp_env::with_var(key, Some("  value  "), || {
            assert_eq!(trimmed_env(key), Some("value".to_string()));
        });
        temp_env::with_var(key, Some("   "), || {
            assert_eq!(trimmed_env(key), None);
        });
        temp_env::with_var(key, None::<&str>, || {
            assert_eq!(trimmed_env(key), None);
        });
    }

    #[test]
    fn session_id_from_env_prefers_first_matching_candidate() {
        temp_env::with_vars(
            [
                ("CODEX_SESSION_ID", None::<&str>),
                ("CODEX_THREAD_ID", Some("thread-id-value")),
            ],
            || {
                assert_eq!(
                    session_id_from_env(HookAgent::Codex),
                    Some("thread-id-value".to_string())
                );
            },
        );

        temp_env::with_vars(
            [
                ("CODEX_SESSION_ID", Some("session-id-value")),
                ("CODEX_THREAD_ID", Some("thread-id-value")),
            ],
            || {
                assert_eq!(
                    session_id_from_env(HookAgent::Codex),
                    Some("session-id-value".to_string())
                );
            },
        );
    }

    #[test]
    fn shell_unescaped_path_undoes_backslash_escapes() {
        let escaped = std::path::Path::new("project\\@team");
        assert_eq!(
            shell_unescaped_path(escaped),
            Some(std::path::PathBuf::from("project@team"))
        );

        let plain = std::path::Path::new("project");
        assert_eq!(shell_unescaped_path(plain), None);
    }

    #[test]
    fn resolve_context_cwd_accepts_a_real_directory_without_unescaping() {
        let real_dir = env::temp_dir();
        assert_eq!(resolve_context_cwd(&real_dir), Some(real_dir));
    }

    #[test]
    fn resolve_context_cwd_returns_none_for_an_escaped_path_that_still_does_not_exist() {
        let missing = std::path::Path::new("/does/not/exist\\@team");
        assert_eq!(resolve_context_cwd(missing), None);
    }

    #[test]
    fn resolve_known_session_id_prefers_hint_over_env_and_storage() {
        let resolved = resolve_known_session_id(HookAgent::Claude, Some("hinted-session"), || {
            panic!("lookup_stored must not run when a hint is present")
        })
        .expect("resolve known session id");
        assert_eq!(resolved, Some("hinted-session".to_string()));
    }

    #[test]
    fn resolve_known_session_id_falls_back_to_lookup_stored() {
        temp_env::with_var("VIBE_SESSION_ID", None::<&str>, || {
            let resolved = resolve_known_session_id(HookAgent::Vibe, None, || {
                Ok(Some("stored-session".to_string()))
            })
            .expect("resolve known session id");
            assert_eq!(resolved, Some("stored-session".to_string()));
        });
    }

    #[test]
    fn resolve_or_create_session_id_mints_a_default_when_nothing_exists() {
        temp_env::with_var("OPENCODE_SESSION_ID", None::<&str>, || {
            let resolved = resolve_or_create_session_id(
                HookAgent::OpenCode,
                None,
                || Ok(None),
                |_agent| "minted-default".to_string(),
            )
            .expect("resolve or create session id");
            assert_eq!(resolved, "minted-default");
        });
    }
}
