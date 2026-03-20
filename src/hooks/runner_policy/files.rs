use std::fmt;
use std::str::FromStr;

/// Patterns that indicate direct access to task output files.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum TaskOutputPattern {
    PrivateTmpClaude,
    TasksOutputGlob,
    TasksB8mPrefix,
}

impl TaskOutputPattern {
    pub const ALL: &[Self] = &[
        Self::PrivateTmpClaude,
        Self::TasksOutputGlob,
        Self::TasksB8mPrefix,
    ];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::PrivateTmpClaude => "/private/tmp/claude-",
            Self::TasksOutputGlob => "tasks/*.output",
            Self::TasksB8mPrefix => "tasks/b8m",
        }
    }

    #[must_use]
    pub fn matches_any(text: &str) -> bool {
        Self::ALL
            .iter()
            .any(|pattern| text.contains(pattern.as_str()))
    }

    pub const DENY_MESSAGE: &str = "do not read task output files directly. \
             Use the TaskOutput tool to check background task results, \
             or wait for the completion notification";
}

impl fmt::Display for TaskOutputPattern {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for TaskOutputPattern {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .iter()
            .find(|pattern| pattern.as_str() == s)
            .copied()
            .ok_or(())
    }
}

/// Binaries that mutate harness-managed run control files.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ControlFileMutationBinary {
    Cp,
    Install,
    Mv,
    Tee,
}

impl ControlFileMutationBinary {
    #[must_use]
    pub fn is_mutation_binary(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for ControlFileMutationBinary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Cp => "cp",
            Self::Install => "install",
            Self::Mv => "mv",
            Self::Tee => "tee",
        })
    }
}

impl FromStr for ControlFileMutationBinary {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "cp" => Ok(Self::Cp),
            "install" => Ok(Self::Install),
            "mv" => Ok(Self::Mv),
            "tee" => Ok(Self::Tee),
            _ => Err(()),
        }
    }
}

/// Binaries that read harness-managed run control files.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ControlFileReadBinary {
    Cat,
    Head,
    Tail,
    Less,
    More,
}

impl ControlFileReadBinary {
    #[must_use]
    pub fn is_read_binary(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for ControlFileReadBinary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Cat => "cat",
            Self::Head => "head",
            Self::Tail => "tail",
            Self::Less => "less",
            Self::More => "more",
        })
    }
}

impl FromStr for ControlFileReadBinary {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "cat" => Ok(Self::Cat),
            "head" => Ok(Self::Head),
            "tail" => Ok(Self::Tail),
            "less" => Ok(Self::Less),
            "more" => Ok(Self::More),
            _ => Err(()),
        }
    }
}

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

/// Shell and scripting interpreters that must not run control files directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ScriptInterpreter {
    Bash,
    Sh,
    Zsh,
    Node,
    Perl,
    Python,
    Ruby,
}

impl ScriptInterpreter {
    #[must_use]
    pub fn is_interpreter(name: &str) -> bool {
        if matches!(name, "bash" | "sh" | "zsh") {
            return true;
        }
        name.starts_with("node")
            || name.starts_with("perl")
            || name.starts_with("python")
            || name.starts_with("ruby")
    }
}

impl fmt::Display for ScriptInterpreter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Bash => "bash",
            Self::Sh => "sh",
            Self::Zsh => "zsh",
            Self::Node => "node",
            Self::Perl => "perl",
            Self::Python => "python",
            Self::Ruby => "ruby",
        })
    }
}

impl FromStr for ScriptInterpreter {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "bash" => Ok(Self::Bash),
            "sh" => Ok(Self::Sh),
            "zsh" => Ok(Self::Zsh),
            "node" => Ok(Self::Node),
            "perl" => Ok(Self::Perl),
            "python" => Ok(Self::Python),
            "ruby" => Ok(Self::Ruby),
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
