//! The set of prompts agents run with, and the process-wide slot holding the
//! one the daemon resolved at startup.
//!
//! A catalog is either the compiled-in defaults or those defaults with some
//! prompts replaced from configuration. Every render site goes through
//! [`render_prompt`], so customizing a prompt is a configuration edit rather
//! than a code change, and an unusable customization is refused before the
//! agent it belongs to ever starts.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use crate::errors::{CliError, CliErrorKind};

use super::prompt_builtins;
use super::prompt_template::{PromptConfigError, PromptTemplate};

/// One configurable prompt. The variants are the render sites: a triage
/// escalation judgment, an ordinary board worker, and the two workflow agents.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum PromptId {
    Evaluation,
    ReadOnlyReview,
    TriageEscalation,
    Worker,
    WriteImplementation,
}

impl PromptId {
    /// Every prompt, in configuration-key order.
    pub(crate) const ALL: [Self; 5] = [
        Self::Evaluation,
        Self::ReadOnlyReview,
        Self::TriageEscalation,
        Self::Worker,
        Self::WriteImplementation,
    ];

    /// The `snake_case` name this prompt is configured under.
    #[must_use]
    pub(crate) const fn config_key(self) -> &'static str {
        match self {
            Self::Evaluation => "evaluation",
            Self::ReadOnlyReview => "read_only_review",
            Self::TriageEscalation => "triage_escalation",
            Self::Worker => "worker",
            Self::WriteImplementation => "write_implementation",
        }
    }

    #[must_use]
    pub(crate) fn from_config_key(key: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|id| id.config_key() == key)
    }

    #[must_use]
    const fn builtin_template(self) -> &'static str {
        match self {
            Self::Evaluation => prompt_builtins::EVALUATION,
            Self::ReadOnlyReview => prompt_builtins::READ_ONLY_REVIEW,
            Self::TriageEscalation => prompt_builtins::TRIAGE_ESCALATION,
            Self::Worker => prompt_builtins::WORKER,
            Self::WriteImplementation => prompt_builtins::WRITE_IMPLEMENTATION,
        }
    }

    /// The variable names a template for this prompt may reference.
    #[must_use]
    pub(crate) const fn allowed_variables(self) -> &'static [&'static str] {
        match self {
            Self::Evaluation => prompt_builtins::EVALUATION_VARIABLES,
            Self::ReadOnlyReview => prompt_builtins::READ_ONLY_REVIEW_VARIABLES,
            Self::TriageEscalation => prompt_builtins::TRIAGE_ESCALATION_VARIABLES,
            Self::Worker => prompt_builtins::WORKER_VARIABLES,
            Self::WriteImplementation => prompt_builtins::WRITE_IMPLEMENTATION_VARIABLES,
        }
    }
}

/// Every prompt's active template, plus any customization that parsed but
/// cannot be used.
///
/// A prompt whose override names a variable that does not exist keeps its
/// entry in `errors` instead of silently falling back to the builtin: the
/// operator asked for something impossible, and the render site turns that
/// into a refused spawn rather than an agent running the wrong prompt.
#[derive(Debug)]
pub(crate) struct PromptCatalog {
    templates: BTreeMap<PromptId, PromptTemplate>,
    errors: BTreeMap<PromptId, PromptConfigError>,
    customized: BTreeSet<PromptId>,
}

impl PromptCatalog {
    /// The compiled-in defaults, customizing nothing.
    #[must_use]
    pub(crate) fn builtin() -> Self {
        Self {
            templates: PromptId::ALL
                .into_iter()
                .map(|id| (id, PromptTemplate::new(id.builtin_template())))
                .collect(),
            errors: BTreeMap::new(),
            customized: BTreeSet::new(),
        }
    }

    /// Parse a prompt configuration document: an object keyed by prompt name,
    /// each value either the prompt text or its lines.
    ///
    /// # Errors
    /// Returns a workflow parse error when the document is not an object of
    /// known prompt names mapped to text.
    pub(crate) fn from_json(bytes: &[u8]) -> Result<Self, CliError> {
        let document: BTreeMap<String, serde_json::Value> = serde_json::from_slice(bytes)
            .map_err(|error| parse_error(format!("prompt configuration is not JSON: {error}")))?;
        let mut catalog = Self::builtin();
        for (key, value) in document {
            let id = PromptId::from_config_key(&key).ok_or_else(|| {
                parse_error(format!("prompt configuration names unknown prompt '{key}'"))
            })?;
            let text = prompt_text(&key, &value)?;
            if text.trim().is_empty() {
                return Err(parse_error(format!("prompt '{key}' is empty")));
            }
            let template = PromptTemplate::new(text);
            if let Err(error) = template.validate_names(id.allowed_variables()) {
                catalog.errors.insert(id, error);
            }
            catalog.templates.insert(id, template);
            catalog.customized.insert(id);
        }
        Ok(catalog)
    }

    /// The template to render `id` with.
    ///
    /// # Errors
    /// Returns an invalid-transition error when this prompt was customized
    /// with a template referencing variables that do not exist for it.
    pub(crate) fn template(&self, id: PromptId) -> Result<&PromptTemplate, CliError> {
        if let Some(error) = self.errors.get(&id) {
            return Err(CliErrorKind::invalid_transition(format!(
                "configured prompt '{}' is unusable: {error}",
                id.config_key()
            ))
            .into());
        }
        Ok(self
            .templates
            .get(&id)
            .expect("every catalog starts from the builtins, which cover every prompt"))
    }

    /// Whether nothing has been customized, so every prompt renders exactly
    /// as the shipped defaults do.
    #[must_use]
    pub(crate) fn is_builtin(&self) -> bool {
        self.customized.is_empty()
    }

    /// The configuration keys this catalog customizes, for startup logging.
    #[must_use]
    pub(crate) fn customized_prompts(&self) -> Vec<&'static str> {
        self.customized
            .iter()
            .map(|id| id.config_key())
            .collect::<Vec<_>>()
    }
}

fn prompt_text(key: &str, value: &serde_json::Value) -> Result<String, CliError> {
    match value {
        serde_json::Value::String(text) => Ok(text.clone()),
        serde_json::Value::Array(lines) => lines
            .iter()
            .map(|line| {
                line.as_str().map(ToString::to_string).ok_or_else(|| {
                    parse_error(format!("prompt '{key}' has a line that is not text"))
                })
            })
            .collect::<Result<Vec<_>, _>>()
            .map(|lines| lines.join("\n")),
        _ => Err(parse_error(format!(
            "prompt '{key}' must be text or an array of lines"
        ))),
    }
}

fn parse_error(detail: String) -> CliError {
    CliErrorKind::workflow_parse(detail).into()
}

static ACTIVE_PROMPT_CATALOG: Mutex<Option<Arc<PromptCatalog>>> = Mutex::new(None);

/// `cargo test` shares one process across threads, so every test that installs
/// a scoped catalog holds this first. Under nextest each test already runs in
/// its own process and the lock is uncontended.
#[cfg(test)]
pub(crate) static PROMPT_CATALOG_TEST_LOCK: Mutex<()> = Mutex::new(());

fn active_catalog_slot() -> MutexGuard<'static, Option<Arc<PromptCatalog>>> {
    match ACTIVE_PROMPT_CATALOG.lock() {
        Ok(slot) => slot,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn builtin_catalog() -> Arc<PromptCatalog> {
    static BUILTIN: OnceLock<Arc<PromptCatalog>> = OnceLock::new();
    Arc::clone(BUILTIN.get_or_init(|| Arc::new(PromptCatalog::builtin())))
}

/// The catalog every render site resolves against: whatever the daemon
/// installed at startup, or the compiled-in defaults when it installed
/// nothing.
#[must_use]
pub(crate) fn active_prompt_catalog() -> Arc<PromptCatalog> {
    active_catalog_slot()
        .as_ref()
        .map_or_else(builtin_catalog, Arc::clone)
}

/// Install the catalog for the rest of the process. Called once, from daemon
/// startup, after configuration has been resolved.
pub(crate) fn install_prompt_catalog(catalog: PromptCatalog) {
    *active_catalog_slot() = Some(Arc::new(catalog));
}

/// Install a catalog for the lifetime of the returned guard. Tests use this to
/// exercise a customized prompt without leaking it into sibling tests.
#[cfg(test)]
#[must_use]
pub(crate) fn scoped_prompt_catalog(catalog: PromptCatalog) -> PromptCatalogGuard {
    let mut slot = active_catalog_slot();
    let previous = slot.take();
    *slot = Some(Arc::new(catalog));
    drop(slot);
    PromptCatalogGuard { previous }
}

#[cfg(test)]
pub(crate) struct PromptCatalogGuard {
    previous: Option<Arc<PromptCatalog>>,
}

#[cfg(test)]
impl Drop for PromptCatalogGuard {
    fn drop(&mut self) {
        *active_catalog_slot() = self.previous.take();
    }
}

/// Render one prompt from the active catalog.
///
/// # Errors
/// Returns an error when the prompt is customized with an unusable template,
/// or when it references something this item does not have. Both are refusals
/// the caller turns into a failed spawn, before the agent starts.
pub(crate) fn render_prompt(
    id: PromptId,
    variables: &BTreeMap<&'static str, String>,
) -> Result<String, CliError> {
    active_prompt_catalog()
        .template(id)?
        .render(variables)
        .map_err(|error| {
            CliErrorKind::invalid_transition(format!(
                "prompt '{}' cannot be rendered for this item: {error}",
                id.config_key()
            ))
            .into()
        })
}

#[cfg(test)]
#[path = "prompt_catalog_tests.rs"]
mod tests;
