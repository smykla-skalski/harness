# Command log

Append one row for every `harness record` invocation.

- `ran_at`: UTC timestamp
- `command`: exact recorded command line
- `exit_code`: command exit status
- `artifact`: relative path to the captured stdout/stderr file under `commands/`

| ran_at | command | exit_code | artifact |
| --- | --- | --- | --- |
