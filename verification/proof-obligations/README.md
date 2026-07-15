# Proof-obligation handoff

These files separate two claims that must not be conflated:

- `bounded-model.json` is `passed_bounded` only for the exact finite Python model and bounds it
  records.
- `implementation-refinement.json` remains `under_test`. The source-model lane passed, while the
  implementation-aware ESSO lane is explicitly blocked because no versioned replay adapter is
  available.

Validate structure and revision/artifact bindings with:

```sh
python3 /path/to/zrm-proof-obligation-handoff/scripts/validate_obligation.py \
  verification/proof-obligations/bounded-model.json --repo-root .
python3 /path/to/zrm-proof-obligation-handoff/scripts/validate_obligation.py \
  verification/proof-obligations/implementation-refinement.json --repo-root .
```

Validation treats replay arguments as untrusted data and never executes them. Run a replay only
after independently reviewing the checked-in program and command.
