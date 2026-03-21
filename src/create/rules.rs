use std::fmt;
use std::str::FromStr;

use crate::kernel::gate::Gate;

pub const SKILL_NAME: &str = "suite:create";

pub const PREWRITE_GATE: Gate = Gate {
    question: "suite:create/prewrite: approve current proposal?",
    options: &["Approve proposal", "Request changes", "Cancel"],
};

pub const POSTWRITE_GATE: Gate = Gate {
    question: "suite:create/postwrite: approve saved suite?",
    options: &["Approve suite", "Request changes", "Cancel"],
};

pub const COPY_GATE: Gate = Gate {
    question: "suite:create/copy: copy run command?",
    options: &["Copy command", "Skip"],
};

/// Kind of result artifact produced by the suite:create pipeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ResultKind {
    Inventory,
    Coverage,
    Variants,
    Schema,
    Proposal,
    EditRequest,
}

impl ResultKind {
    pub const ALL: &[Self] = &[
        Self::Inventory,
        Self::Coverage,
        Self::Variants,
        Self::Schema,
        Self::Proposal,
        Self::EditRequest,
    ];
}

impl fmt::Display for ResultKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Inventory => "inventory",
            Self::Coverage => "coverage",
            Self::Variants => "variants",
            Self::Schema => "schema",
            Self::Proposal => "proposal",
            Self::EditRequest => "edit-request",
        })
    }
}

impl FromStr for ResultKind {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "inventory" => Ok(Self::Inventory),
            "coverage" => Ok(Self::Coverage),
            "variants" => Ok(Self::Variants),
            "schema" => Ok(Self::Schema),
            "proposal" => Ok(Self::Proposal),
            "edit-request" => Ok(Self::EditRequest),
            _ => Err(()),
        }
    }
}

/// Named worker agents in the suite:create pipeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum Worker {
    CoverageReader,
    VariantAnalyzer,
    SchemaVerifier,
    SuiteWriter,
    BaselineWriter,
    GroupWriter,
}

impl Worker {
    pub const ALL: &[Self] = &[
        Self::CoverageReader,
        Self::VariantAnalyzer,
        Self::SchemaVerifier,
        Self::SuiteWriter,
        Self::BaselineWriter,
        Self::GroupWriter,
    ];
}

impl fmt::Display for Worker {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::CoverageReader => "coverage-reader",
            Self::VariantAnalyzer => "variant-analyzer",
            Self::SchemaVerifier => "schema-verifier",
            Self::SuiteWriter => "suite-writer",
            Self::BaselineWriter => "baseline-writer",
            Self::GroupWriter => "group-writer",
        })
    }
}

impl FromStr for Worker {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "coverage-reader" => Ok(Self::CoverageReader),
            "variant-analyzer" => Ok(Self::VariantAnalyzer),
            "schema-verifier" => Ok(Self::SchemaVerifier),
            "suite-writer" => Ok(Self::SuiteWriter),
            "baseline-writer" => Ok(Self::BaselineWriter),
            "group-writer" => Ok(Self::GroupWriter),
            _ => Err(()),
        }
    }
}
