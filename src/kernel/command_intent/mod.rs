mod fallback;
mod harness;
mod observed;
mod parsed;
mod shell;
#[cfg(test)]
mod tests;

pub use harness::{
    HarnessCommandInvocationRef, semantic_harness_subcommand, semantic_harness_tail,
};
pub use observed::ObservedCommand;
pub use parsed::ParsedCommand;
pub use shell::{
    command_heads, contains_subshell_pattern, is_env_assignment, is_shell_chain_op,
    is_shell_control_op, is_shell_flow_word, is_shell_redirect_op, normalized_binary_name,
    path_like_words, significant_words,
};
