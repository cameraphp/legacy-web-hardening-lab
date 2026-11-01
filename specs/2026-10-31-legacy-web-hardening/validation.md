# Validation — legacy-web-hardening-lab (2026-10-31)

This is executable documentation. Every validation ID below is printed **literally** as
`PASS <ID> ...` or `FAIL <ID> ...` by the command that checks it. Run everything from the project root
in PowerShell. The only host prerequisites are Docker Desktop (Linux containers) and PowerShell.

**Evidence:**
- `scripts/lab.ps1` writes each command's sanitized stdout to `artifacts/evidence/<command>.log`.
  That folder is Git-ignored and disposable.
- The evidence never contains session IDs, keys, full cookies or full header dumps.
- **Summary lines:** the tester ends with `SUMMARY tester passed=<n> failed=<n>`, and the host-side
  checks end with `SUMMARY host passed=<n> failed=<n>`.

## Normal lifecycle

```text
up -> test -> backup -> verify-backup -> migrate-dry-run -> migrate-apply -> rollback -> down
```

```powershell
.\scripts\lab.ps1 up
.\scripts\lab.ps1 test
.\scripts\lab.ps1 backup
.\scripts\lab.ps1 verify-backup
.\scripts\lab.ps1 migrate-status
.\scripts\lab.ps1 migrate-dry-run
.\scripts\lab.ps1 migrate-apply
.\scripts\lab.ps1 rollback
.\scripts\lab.ps1 down
```

**Additional checks before declaring success:** `docker compose config` (run by `test` as V-CFG-01),
`docker compose ps` (V-RUN-01), origin publishing no host port (V-CFG-03, V-RUN-01), and a project tree
free of runtime secrets and data (V-HYG-01).

## Destructive reset (separate; not part of the lifecycle)

```powershell
.\scripts\lab.ps1 reset                    # refused: prints the remediation and exits 2, removes nothing
.\scripts\lab.ps1 reset -ConfirmLabReset   # docker compose -p legacy-web-hardening-lab down -v --remove-orphans
```

`reset` removes only this Compose project's containers, networks and named volumes
(`legacy-web-hardening-lab_legacy_state` and `legacy-web-hardening-lab_lab_backups`). It never runs a
global prune. Locally built images are kept.

## Validation catalogue

- **Implementation paths** are relative to the project root.
- **Runner key:**
  - **H** is a host-side check in `scripts/lab.ps1`, using the Docker CLI and PowerShell only.
  - **T** is the `tester` container (`docker/tester/run-acceptance.sh`).
  - **B** is the `backup` container.
  - **M** is the `migrator` container.
  - **W** is a wrapper assertion in `scripts/lab.ps1` around a helper's exit code or output.

### Compose configuration and runtime exposure (`lab.ps1 test`)

| ID | Req | Runner / implementation | Command | Expected result | Evidence | Cleanup |
|---|---|---|---|---|---|---|
| V-CFG-01 | REQ-ARCH-001 | H: `scripts/lab.ps1` (Test-ComposeConfig) | `docker compose config --format json` | Exit 0. Project name `legacy-web-hardening-lab`. Services `edge`, `origin`, `tester`, `backup`, `migrator` defined. | `artifacts/evidence/test.log` | none |
| V-CFG-02 | REQ-ARCH-002, REQ-SAFE-001 | H | Same JSON | Only `edge` has `ports`: exactly one entry, `host_ip=127.0.0.1`, `published=8443`, `target=443` | test.log | none |
| V-CFG-03 | REQ-ARCH-001/003 | H | Same JSON | `origin` has no `ports` and its only network is `origin_net`. `origin_net.internal=true`, subnet `172.28.0.0/24`. Static IPs: edge `.2`, origin `.10`, tester `.20`. | test.log | none |
| V-CFG-04 | REQ-ARCH-004 | H | Same JSON, plus the `FROM` lines in `docker/*/Dockerfile` | Every `FROM` is `nginx:1.30.6-alpine3.24`, `php:8.5.12-apache-trixie` or `alpine:3.24.3`. No `latest` anywhere. Every service image is an explicit local tag. | test.log | none |
| V-CFG-05 | REQ-ARCH-005, REQ-SAFE-001 | H | Same JSON | `backup` and `migrator` use `network_mode: none`. No service has a host bind mount, only named volumes and tmpfs. `origin` mounts `legacy_state` read-only. `tester` has no ports. | test.log | none |
| V-RUN-01 | REQ-ARCH-002/003 | H | `docker compose ps --format json`, `docker compose port edge 443` | `edge` and `origin` are running. Origin's publishers list no published port. `port edge 443` returns `127.0.0.1:8443`. | test.log | none |
| V-RUN-02 | REQ-ARCH-002, REQ-SAFE-001 | H | `Get-NetTCPConnection -LocalPort 8443 -State Listen` | Every listener on 8443 is a loopback address (`127.0.0.1` or `::1`), with no `0.0.0.0` or `::` listener | test.log | none |

### TLS edge (`lab.ps1 test` → tester)

| ID | Req | Runner / implementation | Command (inside tester) | Expected result | Evidence | Cleanup |
|---|---|---|---|---|---|---|
| V-TLS-01 | REQ-EDGE-001 | T: `run-acceptance.sh` | `curl https://localhost/` (default verification) | curl exit 60, a certificate verification failure | test.log | none |
| V-TLS-02 | REQ-EDGE-001 | T | `curl -k https://localhost/` (explicit, lab only) | HTTP 200 | test.log | none |
| V-TLS-03 | REQ-EDGE-001 | T | `openssl s_client -tls1_2` | Handshake succeeds, protocol `TLSv1.2` | test.log | none |
| V-TLS-04 | REQ-EDGE-001 | T | `openssl s_client -tls1_3` | Handshake succeeds, protocol `TLSv1.3` | test.log | none |
| V-TLS-05 | REQ-EDGE-001 | T | `openssl s_client -tls1_1 -cipher DEFAULT@SECLEVEL=0` | Handshake fails, so TLS 1.1 is not negotiated | test.log | none |
| V-TLS-06 | REQ-EDGE-001, REQ-SAFE-003 | T | `openssl s_client` and `openssl x509 -noout` | Subject equals issuer (self-signed), CN `localhost`, SAN includes `DNS:localhost` and `IP Address:127.0.0.1`, validity ≤ 8 days. Only these fields are printed, never the key or PEM. | test.log | none |

### Edge behaviour (`lab.ps1 test` → tester, plus H for V-EDGE-10)

| ID | Req | Runner / implementation | Command | Expected result | Evidence | Cleanup |
|---|---|---|---|---|---|---|
| V-EDGE-01 | REQ-SAFE-002, REQ-ORIGIN-004 | T | `GET /` | 200, `text/html; charset=utf-8`, body contains the exact lab-only warning | test.log | none |
| V-EDGE-02 | REQ-EDGE-003 | T | `GET /` headers | `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, CSP containing `default-src 'none'` and `frame-ancestors 'none'`, each present exactly once | test.log | none |
| V-EDGE-03 | REQ-EDGE-003 | T | `GET /` headers | No `Strict-Transport-Security` | test.log | none |
| V-EDGE-04 | REQ-EDGE-004, REQ-ORIGIN-002/003 | T | `GET /` and `GET /session` headers | `Server: nginx` exactly. No `X-Powered-By`. No `Apache`, `PHP/` or `nginx/` version strings in the headers. | test.log | none |
| V-EDGE-05 | REQ-EDGE-002 | T | `GET /lab/request-context?probe=<bad-token>` with `Host: unexpected.invalid` | 421, no `Set-Cookie`, body is the edge's plain-text rejection (not an origin JSON) | test.log | none |
| V-EDGE-06 | REQ-EDGE-005, REQ-ORIGIN-002 | T | `TRACE /` | 405 | test.log | none |
| V-EDGE-07 | REQ-EDGE-005 | T | `POST`, `PUT`, `DELETE`, `OPTIONS /` | 405 for each | test.log | none |
| V-EDGE-08 | REQ-EDGE-006, REQ-ORIGIN-002 | T | `GET /static/` (a directory with no index) | 404 with the generic body and no `Index of`. With `mod_autoindex` disabled, Apache's default handler doesn't serve an index-less directory. It answers a generic 404, so the directory's existence isn't even confirmed. This was observed during implementation and specified as exactly 404. | test.log | none |
| V-EDGE-09 | REQ-EDGE-006, REQ-ORIGIN-002 | T | `GET /does-not-exist` | 404, generic body with no `Apache`, `/var/`, `PHP` or `Warning` | test.log | none |
| V-EDGE-10 | REQ-EDGE-002 | H: reads the tester's `PROBE bad=<t1> good=<t2>` line, then `docker compose logs origin` | — | The origin access log contains `t2` (positive control) and does **not** contain `t1` | test.log | none |

### Forwarded headers and origin restriction (`lab.ps1 test` → tester)

| ID | Req | Runner / implementation | Command | Expected result | Evidence | Cleanup |
|---|---|---|---|---|---|---|
| V-FWD-01 | REQ-FWD-002/003, REQ-ORIGIN-004 | T | `GET /lab/request-context` through the edge | `scheme=https`, `forwarded_port=443`, `host=localhost`, `via_trusted_edge=true`, `client_ip` equals curl's `%{local_ip}` (the address Nginx observed), and `x_forwarded_for_unconsumed=0`. `mod_remoteip` removes the `X-Forwarded-For` entries it consumed from the trusted edge, so any leftover entries would mean an appended, client-controlled chain. | test.log | none |
| V-FWD-02 | REQ-FWD-001/002/003 | T | Same, with forged `X-Forwarded-For`, `X-Real-IP`, `Forwarded`, `CF-Connecting-IP`, `True-Client-IP`, `X-Forwarded-Proto: http`, `X-Forwarded-Host`, `X-Forwarded-Port: 80` and `X-Client-IP` | Same context as V-FWD-01. `unexpected_forwarding_headers` is empty. No forged value (`203.0.113.*`, `forged.invalid`) appears in the response. | test.log | none |
| V-FWD-03 | REQ-FWD-004, REQ-ORIGIN-003 | T | `GET /lab/request-context` | The JSON keys are exactly `client_ip`, `scheme`, `host`, `forwarded_port`, `via_trusted_edge`, `x_forwarded_for_unconsumed` and `unexpected_forwarding_headers`. The body has no `DOCUMENT_ROOT`, `/var/www`, `PATH=`, `HTTP_COOKIE` or `LABSESSID`. | test.log | none |
| V-ORIGIN-01 | REQ-ORIGIN-001 | T (tester @ 172.28.0.20 on `origin_net`) | `curl http://172.28.0.10/health` (direct, bypassing Nginx) | 403 | test.log | none |
| V-ORIGIN-02 | REQ-ORIGIN-001, REQ-FWD-003 | T | Direct request with forged `X-Forwarded-For: 172.28.0.2` | 403, because a forged header can't impersonate the edge | test.log | none |
| V-ORIGIN-03 | REQ-ORIGIN-001/004 | T | `GET /health` through the edge, after the direct attempts | 200 with body exactly `{"status":"ok"}` | test.log | none |

### Session and cookie (`lab.ps1 test` → tester)

| ID | Req | Runner / implementation | Command | Expected result | Evidence | Cleanup |
|---|---|---|---|---|---|---|
| V-SESS-01 | REQ-SESSION-001, REQ-SAFE-003, REQ-TEST-001 | T | `GET /session` (fresh jar) | Exactly one `Set-Cookie`, named `LABSESSID`, with `secure`, `HttpOnly`, `SameSite=Lax` and `path=/`. No `Domain`, no `PHPSESSID`. Only attribute names are printed, never the ID. | test.log | Jar in tester `/tmp`, discarded with the container |
| V-SESS-02 | REQ-SESSION-004, REQ-ORIGIN-004 | T | `GET /session` twice with the jar | Counter 1, then 2 | test.log | Same |
| V-SESS-03 | REQ-SESSION-002 | T | `GET /session` with `Cookie: LABSESSID=<client-chosen>` | Server issues a different ID (only the comparison result is printed) and the counter is 1 | test.log | Same |
| V-SESS-04 | REQ-SESSION-003 | T | `GET /session` headers | `Cache-Control` contains `no-store` | test.log | none |

### Data, backup, migration, rollback

| ID | Req | Runner / implementation | Command | Expected result | Evidence | Cleanup |
|---|---|---|---|---|---|---|
| V-DATA-01 | REQ-DATA-001 | M: `docker/origin/bin/migrate.php init`, plus a W check on the origin read-only mount | `.\scripts\lab.ps1 up` | The fixture is seeded or verified: marker `LAB_BACKUP_FIXTURE=v1`, 3 items, schema version ≥ 1, `integrity_check` ok. The origin's state mount is read-only. | `artifacts/evidence/up.log` | Volume persists until `reset` |
| V-BAK-01 | REQ-BACKUP-001 | B: `docker/backup/backup-verify.sh create` | `.\scripts\lab.ps1 backup` | Archive and `.sha256` manifest created. Live hash stable across the snapshot. Snapshot integrity ok. Previous evidence invalidated. | `backup.log` | Newest 5 archives kept in `lab_backups` |
| V-BAK-02 | REQ-BACKUP-001, REQ-MIGRATE-003 | W: `migrate.php gate-check` after create | (part of `backup`) | Exit 3, `GATE REFUSED` with remediation (no verified evidence yet) | `backup.log` | none |
| V-BAK-03 | REQ-BACKUP-002 | B: `backup-verify.sh verify` | `.\scripts\lab.ps1 verify-backup` | `sha256sum -c` passes on the manifest, and the archive members are exactly `lab.sqlite`, `backup-meta.env` and `CONTENTS.sha256` | `verify-backup.log` | none |
| V-BAK-04 | REQ-BACKUP-002 | B | (same) | The restore goes into a disposable directory under `/tmp/restore.*`. `CONTENTS.sha256` passes. `integrity_check` ok. Marker `LAB_BACKUP_FIXTURE=v1`, 3 items, schema matches the metadata. A write probe confirms the live mount is read-only. The restore directory is removed. | `verify-backup.log` | Restore directory deleted; container `--rm` |
| V-BAK-05 | REQ-BACKUP-002, REQ-MIGRATE-003 | B + W: evidence written, then `gate-check` | (same) | `verified/latest.json` written. `gate-check` exits 0 with `GATE PASS`. | `verify-backup.log` | Evidence persists until the next `backup` |
| V-MIG-01 | REQ-MIGRATE-001 | M: `migrate.php status` | `.\scripts\lab.ps1 migrate-status` | Prints schema version, marker, item count, data digest prefix, live SHA-256 prefix, gate state, and the last 5 journal rows | `migrate-status.log` | none |
| V-MIG-02 | REQ-MIGRATE-002 | M: `migrate.php dry-run` | `.\scripts\lab.ps1 migrate-dry-run` | The disposable copy reaches version 2, while the live SHA-256 before equals after and the live version stays 1. (If 002 is already applied: no-op, exit 0.) | `migrate-dry-run.log` | Copy deleted |
| V-MIG-03 | REQ-MIGRATE-003/004 | M: `migrate.php apply` | `.\scripts\lab.ps1 migrate-apply` | `GATE PASS` printed **before** any change, then version 1 → 2, `lab_change_log` present, data digest unchanged, journal row written | `migrate-apply.log` | Reverted by `rollback` |
| V-MIG-04 | REQ-MIGRATE-004, REQ-OPS-002 | W: second `apply` | (part of `migrate-apply`) | Exit 0, `ALREADY APPLIED`, live SHA-256 unchanged | `migrate-apply.log` | none |
| V-MIG-05 | REQ-MIGRATE-004 | T: `run-acceptance.sh health V-MIG-05` | (part of `migrate-apply`) | `/health` through the edge returns 200 `{"status":"ok"}` | `migrate-apply.log` | none |
| V-RB-01 | REQ-ROLLBACK-001 | M: `migrate.php rollback` | `.\scripts\lab.ps1 rollback` | Version 2 → 1, `lab_change_log` absent, marker intact, data digest equals the one recorded at apply, `integrity_check` ok | `rollback.log` | none |
| V-RB-02 | REQ-ROLLBACK-001 | T: `health V-RB-02` | (part of `rollback`) | `/health` through the edge returns 200 `{"status":"ok"}` | `rollback.log` | none |
| V-RB-03 | REQ-ROLLBACK-001, REQ-OPS-002 | W: second `rollback` | (part of `rollback`) | Exit 0, `NOTHING TO ROLL BACK`, live SHA-256 unchanged | `rollback.log` | none |
| V-RB-04 | REQ-MIGRATE-003 | W: `gate-check` after a real rollback | (part of `rollback`) | Exit 3, `GATE REFUSED` (the live DB changed since the verified backup), with remediation | `rollback.log` | none |

### Operations, hygiene, documentation (`lab.ps1 test`)

| ID | Req | Runner / implementation | Command | Expected result | Evidence | Cleanup |
|---|---|---|---|---|---|---|
| V-OPS-01 | REQ-OPS-001, REQ-TEST-001 | H: static inspection of `scripts/lab.ps1` and `docker/tester/Dockerfile` | (part of `test`) | `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` present. The `ValidateSet` lists exactly the 10 commands. The tester image is a container (no host curl). | test.log | none |
| V-OPS-02 | REQ-OPS-002 | Manual: run the whole lifecycle a second time | Lifecycle commands again | Every command passes again, or a gate refusal prints a precise remediation | `BUILD_REPORT.md` §6 | none |
| V-OPS-03 | REQ-OPS-003 | H: runs `powershell -NoProfile -File scripts/lab.ps1 reset` without the flag | (part of `test`) | Exit 2 with the `-ConfirmLabReset` remediation. Both named volumes still exist afterwards. | test.log | none |
| V-HYG-01 | REQ-SAFE-003 | H: recursive scan of the project tree | (part of `test`) | No `*.key`, `*.pem`, `*.crt`, `*.sqlite*`, `*.tar.gz`, `.env` or `.runtime` anywhere, and no `.git` or `node_modules` directory other than the repository's own top-level `.git` (version-control metadata, excluded from the scan). The only files under `artifacts/` are `README.md` and `artifacts/evidence/*.log`, which are ignored. | test.log | none |
| V-DOC-01 | REQ-SAFE-002, REQ-DOC-001 | H | (part of `test`) | `README.md` contains the exact lab-only warning (built from `[char]0x2014`, so `lab.ps1` stays ASCII-only) | test.log | none |
| V-DOC-02 | REQ-SAFE-004, REQ-EDGE-007, REQ-ROLLBACK-002, REQ-DOC-001 | H | (part of `test`) | The README has the required sections and the label "Cloudflare-style edge/origin separation and header sanitation only". Lines containing `production-ready`, `compliant`, `certified`, `fully secure` or `Cloudflare-protected` also contain a negation. | test.log | none |

## Coverage summary

- **Requirements:** 42 IDs, each mapped in `requirements.md`.
- **Validation IDs:** 54 in total. By runner:

  | Runner | Count | IDs |
  |---|---|---|
  | Tester (in `test`) | 25 | TLS 6, EDGE 9, FWD 3, ORIGIN 3, SESS 4 |
  | Host (in `test`) | 13 | CFG 5, RUN 2, EDGE-10, OPS-01, OPS-03, HYG 1, DOC 2 |
  | Data lifecycle | 15 | DATA 1, BAK 5, MIG 5, RB 4. MIG-05 and RB-02 reuse the tester's `health` mode. |
  | Manual | 1 | OPS-02 |

- **`lab.ps1 test`** runs 38 automated acceptance checks (25 tester + 13 host). The lifecycle commands
  add 15 more automated checks.
