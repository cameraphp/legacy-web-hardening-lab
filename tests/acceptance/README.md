# Acceptance tests

> **LAB ONLY — fictional local hardening demonstration; do not use with client data or production systems.**

All acceptance checks run through `scripts\lab.ps1`. HTTP, TLS, cookie, SQLite and backup checks run
**inside containers**, so the only host prerequisites are Docker Desktop and PowerShell. The
authoritative mapping of each ID to its requirement, command, expected result and evidence is
[`specs/2026-10-31-legacy-web-hardening/validation.md`](../../specs/2026-10-31-legacy-web-hardening/validation.md).

## Where each check lives

| Runner | Implementation | IDs |
|---|---|---|
| Tester container | [`docker/tester/run-acceptance.sh`](../../docker/tester/run-acceptance.sh) (`all`) | V-TLS-01..06, V-EDGE-01..09, V-FWD-01..03, V-ORIGIN-01..03, V-SESS-01..04 (25) |
| Host (Docker CLI + PowerShell only) | [`scripts/lab.ps1`](../../scripts/lab.ps1) `test` | V-CFG-01..05, V-RUN-01..02, V-EDGE-10, V-OPS-01, V-OPS-03, V-HYG-01, V-DOC-01..02 (13) |
| Migrator container | [`docker/origin/bin/migrate.php`](../../docker/origin/bin/migrate.php) | V-MIG-01..03, V-RB-01. V-DATA-01's fixture line comes from here too. |
| Backup container | [`docker/backup/backup-verify.sh`](../../docker/backup/backup-verify.sh) | V-BAK-01, V-BAK-03, V-BAK-04 |
| Wrapper assertions | `scripts/lab.ps1` lifecycle commands | V-DATA-01, V-BAK-02, V-BAK-05, V-MIG-04, V-RB-03, V-RB-04. V-MIG-05 and V-RB-02 use the tester's `health` mode. |
| Manual | Second full lifecycle run | V-OPS-02 (recorded in `BUILD_REPORT.md`) |

## Running

```powershell
.\scripts\lab.ps1 up
.\scripts\lab.ps1 test            # 38 checks; ends with TEST OK or a non-zero exit
.\scripts\lab.ps1 backup
.\scripts\lab.ps1 verify-backup
.\scripts\lab.ps1 migrate-dry-run
.\scripts\lab.ps1 migrate-apply
.\scripts\lab.ps1 rollback
.\scripts\lab.ps1 down
```

## Rules the tests follow

- **TLS verification:** a strict client must reject the certificate first (V-TLS-01). Only then does
  the tester use `-k`, explicitly and for this lab only.
- **No secrets in output:** the tests never print session IDs, cookie values, private keys, certificate
  PEMs, environment variables or full header dumps. Only attribute names, status codes, counts and
  short hash prefixes appear.
- **No leftover state:** cookie jars and response files live in the tester container's `/tmp` (tmpfs)
  and are discarded with the container (`--rm`).
- **Idempotent:** the suite works at any migration state and can be re-run. Lifecycle commands that
  can't proceed print a `REMEDIATION:` line and exit non-zero.
- **Destructive reset stays out:** `test` only proves that `reset` without `-ConfirmLabReset` refuses
  and leaves the project volumes untouched (V-OPS-03).
