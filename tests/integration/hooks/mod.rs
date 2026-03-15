// Hook guard/verify integration tests.
// Split by hook type: guard_bash, guard_write, guard_question, guard_stop,
// verify (bash/write/question combined), audit, agent (context/validate).

mod agent;
mod audit;
mod guard_bash;
mod guard_question;
mod guard_stop;
mod guard_write;
mod verify;
