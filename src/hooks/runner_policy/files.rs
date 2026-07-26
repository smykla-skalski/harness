use std::fmt;
use std::str::FromStr;

/// Binaries that mutate suite storage directories.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum SuiteMutationBinary {
    Cp,
    Install,
    Ln,
    Mkdir,
    Mv,
    Rm,
    Rmdir,
    Touch,
}

impl SuiteMutationBinary {
    #[must_use]
    pub fn is_mutation_binary(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for SuiteMutationBinary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Cp => "cp",
            Self::Install => "install",
            Self::Ln => "ln",
            Self::Mkdir => "mkdir",
            Self::Mv => "mv",
            Self::Rm => "rm",
            Self::Rmdir => "rmdir",
            Self::Touch => "touch",
        })
    }
}

impl FromStr for SuiteMutationBinary {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "cp" => Ok(Self::Cp),
            "install" => Ok(Self::Install),
            "ln" => Ok(Self::Ln),
            "mkdir" => Ok(Self::Mkdir),
            "mv" => Ok(Self::Mv),
            "rm" => Ok(Self::Rm),
            "rmdir" => Ok(Self::Rmdir),
            "touch" => Ok(Self::Touch),
            _ => Err(()),
        }
    }
}

/// Python binary names used for inline script detection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum PythonBinary {
    Python,
    Python3,
}

impl PythonBinary {
    #[must_use]
    pub fn is_python(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for PythonBinary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Python => "python",
            Self::Python3 => "python3",
        })
    }
}

impl FromStr for PythonBinary {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "python" => Ok(Self::Python),
            "python3" => Ok(Self::Python3),
            _ => Err(()),
        }
    }
}
