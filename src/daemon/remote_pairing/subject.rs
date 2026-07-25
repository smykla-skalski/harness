//! The external identity a pairing link was minted for.
//!
//! A link created locally belongs to whoever ran the command on the host. A
//! minted link belongs to a person the minting service authenticated somewhere
//! else, and that identity is the only thing tying the link back to a human, so
//! it is stored with the pairing row and named in the audit trail.

use serde::{Deserialize, Serialize};

use super::RemotePairingError;

/// Long enough for any provider handle, short enough that a caller cannot use
/// the pairing metadata column as free storage.
const MAX_SUBJECT_FIELD_CHARS: usize = 200;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize, utoipa::ToSchema)]
pub struct RemotePairingSubject {
    /// Identity provider that authenticated the person, such as `github`.
    pub provider: String,
    /// The provider's stable identifier. A login can be renamed and reused by
    /// someone else, so callers should send the immutable id.
    pub subject_id: String,
    /// What an operator reading the audit trail should see.
    pub display_name: String,
}

impl RemotePairingSubject {
    /// Build a validated subject.
    ///
    /// # Errors
    /// Returns [`RemotePairingError::InvalidSubject`] when a field is blank or
    /// longer than [`MAX_SUBJECT_FIELD_CHARS`].
    pub fn new(
        provider: impl Into<String>,
        subject_id: impl Into<String>,
        display_name: impl Into<String>,
    ) -> Result<Self, RemotePairingError> {
        let subject = Self {
            provider: provider.into().trim().to_owned(),
            subject_id: subject_id.into().trim().to_owned(),
            display_name: display_name.into().trim().to_owned(),
        };
        subject.validate()?;
        Ok(subject)
    }

    /// Re-validate a subject that arrived already built, such as one decoded
    /// from stored metadata or a request body.
    ///
    /// # Errors
    /// Returns [`RemotePairingError::InvalidSubject`] when a field is blank,
    /// too long, or carries a control character.
    pub fn validate(&self) -> Result<(), RemotePairingError> {
        for (label, value) in [
            ("provider", self.provider.as_str()),
            ("subject_id", self.subject_id.as_str()),
            ("display_name", self.display_name.as_str()),
        ] {
            if value.trim().is_empty() {
                return Err(RemotePairingError::InvalidSubject(format!(
                    "pairing subject {label} is required"
                )));
            }
            if value.chars().count() > MAX_SUBJECT_FIELD_CHARS {
                return Err(RemotePairingError::InvalidSubject(format!(
                    "pairing subject {label} exceeds {MAX_SUBJECT_FIELD_CHARS} characters"
                )));
            }
            // These fields are rendered verbatim into audit detail, which an
            // operator reads as one line per event. A newline here would let
            // the caller forge additional lines in that record.
            if value.chars().any(char::is_control) {
                return Err(RemotePairingError::InvalidSubject(format!(
                    "pairing subject {label} must not contain control characters"
                )));
            }
        }
        Ok(())
    }

    /// A single-line rendering for audit detail.
    #[must_use]
    pub fn audit_detail(&self) -> String {
        format!(
            "minted for {}:{} ({})",
            self.provider, self.subject_id, self.display_name
        )
    }
}

#[cfg(test)]
mod tests {
    use super::{MAX_SUBJECT_FIELD_CHARS, RemotePairingSubject};

    #[test]
    fn trims_fields_and_accepts_a_complete_subject() {
        let subject = RemotePairingSubject::new(" github ", " 4242 ", " Ada Lovelace ")
            .expect("complete subject");

        assert_eq!(subject.provider, "github");
        assert_eq!(subject.subject_id, "4242");
        assert_eq!(subject.display_name, "Ada Lovelace");
    }

    #[test]
    fn rejects_a_blank_field_by_name() {
        for (provider, subject_id, display_name, expected) in [
            ("", "4242", "Ada", "provider"),
            ("github", "   ", "Ada", "subject_id"),
            ("github", "4242", "", "display_name"),
        ] {
            let error = RemotePairingSubject::new(provider, subject_id, display_name)
                .expect_err("blank field must be refused");

            assert!(
                error.to_string().contains(expected),
                "error should name {expected}, got {error}"
            );
        }
    }

    /// A newline in any field would otherwise forge extra lines in the audit
    /// record the subject is rendered into.
    #[test]
    fn rejects_control_characters_that_would_forge_audit_lines() {
        for (provider, subject_id, display_name, expected) in [
            ("git\nhub", "4242", "Ada", "provider"),
            ("github", "42\r42", "Ada", "subject_id"),
            (
                "github",
                "4242",
                "Ada\nminted for github:9 (Root)",
                "display_name",
            ),
            ("github", "4242", "Ada\u{7f}", "display_name"),
        ] {
            let error = RemotePairingSubject::new(provider, subject_id, display_name)
                .expect_err("a control character must be refused");

            assert!(error.to_string().contains(expected), "{error}");
            assert!(
                error.to_string().contains("control characters"),
                "rejection should name the cause, got {error}"
            );
        }
    }

    #[test]
    fn audit_detail_stays_on_one_line() {
        let subject =
            RemotePairingSubject::new("github", "4242", "Ada Lovelace").expect("valid subject");

        assert!(!subject.audit_detail().contains('\n'));
    }

    #[test]
    fn rejects_a_field_long_enough_to_abuse_the_metadata_column() {
        let long = "a".repeat(MAX_SUBJECT_FIELD_CHARS + 1);

        let error = RemotePairingSubject::new("github", long.as_str(), "Ada")
            .expect_err("oversized field must be refused");

        assert!(error.to_string().contains("subject_id"), "{error}");
    }
}
