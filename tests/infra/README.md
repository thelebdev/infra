# Infrastructure tests

Tests that verify the platform behaves as documented.

## Status

**Empty.** Tests will land here as services are built.

## Intended structure

- `bootstrap-test.sh` — runs the full bootstrap on a fresh VPS, verifies it completes successfully within the SLA
- `health-checks.sh` — verifies each platform service is reachable and producing expected signals
- `recovery-dry-run.sh` — automated quarterly dry-run
