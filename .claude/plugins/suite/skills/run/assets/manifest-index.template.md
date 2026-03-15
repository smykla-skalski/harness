# Manifest index

Each row is one manifest application event tracked by `harness apply`.

- `copied_at`: UTC timestamp of the applied manifest version
- `manifest`: relative path to the applied manifest in the run
- `validated`: validation result, usually `PASS`
- `applied`: apply result, usually `PASS`
- `notes`: validation artifact path or step label context

| copied_at | manifest | validated | applied | notes |
| --- | --- | --- | --- | --- |
