# Build Report: legacy-web-hardening-lab

> **LAB ONLY — fictional local hardening demonstration; do not use with client data or production systems.**

- **Date:** 2026-10-31 (container clocks show 2026-11-01 UTC)
- **Project path:** `C:\Users\camer\github\improvement-plan\legacy-web-hardening-lab`
- **Status:** built and validated locally, with no failing checks. At the conclusion of its local
  build and validation phase, there was no Git repository, commit or remote. There is no deployment
  and no public endpoint.
- **Report scope:** this report documents the completed local build and validation evidence. The
  later Git publication is recorded in Git history. GitHub Actions CI has not been configured or run
  as part of the build or publication.

## 1. Environment

| Item | Value |
|---|---|
| OS | Windows 11 Pro 10.0.26200 |
| Docker Desktop | 4.96.0 (Engine 29.9.1, API 1.56, containerd v2.4.2, runc 1.5.2) |
| Docker Compose | v5.6.0 |
| Docker context and OS type | `desktop-linux`, `linux` |
| PowerShell | Windows PowerShell 5.1.26100.9711 |
| Python | 3.13.7 (reported by preflight; not used by the lab) |
| Node.js | v24.9.0 (reported by preflight; not used by the lab) |
| Port 8443 at preflight | free |

**Preflight note:** the first preflight stopped because Docker Desktop wasn't running. The Linux engine
pipe was missing. Nothing was created. After the owner started Docker Desktop, the full preflight was
re-run and passed.

## 2. Specification (spec-driven development)

- **Location:** [`specs/2026-10-31-legacy-web-hardening/`](specs/2026-10-31-legacy-web-hardening/)
  - `plan.md`: scope, threat model, trust boundaries, Mermaid topology, design decisions, phases, risk
    controls, image strategy, rollback rehearsal, limitations
  - `requirements.md`: **42 requirement IDs** (SAFE 4, ARCH 5, EDGE 7, FWD 4, ORIGIN 4, SESSION 4, DATA 1,
    BACKUP 2, MIGRATE 4, ROLLBACK 2, OPS 3, TEST 1, DOC 1), with a requirement-to-validation table
  - `validation.md`: **54 validation IDs**, each with runner, implementation path, command, expected
    result, evidence and cleanup
- **Order:** all three files were written before any Docker, PHP, Nginx, script or test file.
- **Coverage:** every requirement maps to at least one validation ID. Every automated validation ID is
  printed literally as `PASS <ID>` by the command that checks it.
- **Spec updates made in the same session,** each grounded in observed behaviour and none weakening a
  control:
  1. **V-EDGE-08** now expects exactly **404** (generic body, no listing) for an index-less directory.
     With `mod_autoindex` disabled, Apache answers 404 instead of 403. That doesn't even confirm the
     directory exists.
  2. **`x_forwarded_for_unconsumed`** replaced the planned "hops" field (plan §5.2, V-FWD-01/03).
     `mod_remoteip` removes the `X-Forwarded-For` entries it consumes from the trusted edge, so PHP
     normally sees none. The leftover count must be 0, and would be above 0 if a proxy appended to a
     client-controlled chain.
  3. **Healthcheck cadence:** `start_interval` is 2 s and the steady interval 60 s. Each probe is an
     expected authz denial, so a long interval keeps the error log readable.

## 3. Architecture summary

- **`edge`:** Nginx 1.30.6, the **only** host port, `127.0.0.1:8443 → 443`.
  - TLS 1.2 and 1.3 only, with an ephemeral self-signed ECDSA certificate (7 days) generated on tmpfs at
    each start.
  - A default server returns **421** for unknown `Host` values.
  - `GET` and `HEAD` only; everything else gets **405**.
  - Header **allowlist** (`proxy_pass_request_headers off`) and rebuilt `X-Forwarded-*` and `X-Real-IP`.
  - Security headers set; **no HSTS**, deliberately.
  - Labelled *Cloudflare-style edge/origin separation and header sanitation only*.
- **`origin`:** Apache 2.4.69 + PHP 8.5.12 at `172.28.0.10`, on `origin_net` (`internal: true`) only,
  with **no `ports:`**.
  - `Require expr "%{CONN_REMOTE_ADDR} == '172.28.0.2'"`. Plain `Require ip` would see the
    `mod_remoteip`-rewritten address.
  - `mod_remoteip` trusts only `172.28.0.2`.
  - Strict cookie-only `LABSESSID` sessions.
  - Fixture state mounted **read-only**.
- **One-shot helpers:**
  - `tester` (Alpine) runs on `edge_net` plus `origin_net` at `172.28.0.20`;
  - `backup` (Alpine) and `migrator` (the origin image) run with `network_mode: none`.
- **Volumes:** `legacy_state` (synthetic SQLite fixture) and `lab_backups` (archives, manifests,
  evidence). There are no host bind mounts.
- **Container hardening:** `read_only: true`, tmpfs, `cap_drop: ALL` with minimal additions, and
  `no-new-privileges`.

## 4. Images and component versions

| Base image (pinned tag) | Digest resolved at build (record only; not pinned) | Used by |
|---|---|---|
| `nginx:1.30.6-alpine3.24` | `sha256:0e52bd054126cdc040b1276c0af347aeb02a41b9cfe305d6094767ac30e97949` | edge (adds `openssl`) |
| `php:8.5.12-apache-trixie` | `sha256:4cc63b3d4e05c40da73e7af5d39364ca2678ac07208919497bda3bbab975be95` | origin, migrator |
| `alpine:3.24.3` | `sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a` | tester (`bash curl openssl jq ca-certificates`), backup (`bash sqlite`) |

**Components observed in the built images:**
- **Edge:** nginx 1.30.6 and OpenSSL 3.5.9.
- **Origin:** Apache 2.4.69 (Debian), PHP 8.5.12, SQLite library 3.46.1.
- **Tester:** curl 8.23.0, OpenSSL 3.5.9, jq 1.8.2, bash 5.3.9.
- **Backup:** sqlite3 3.53.4, bash 5.3.9.

**Locally built images** (project-scoped tags): `legacy-web-hardening-lab/edge:local`, `…/origin:local`,
`…/tester:local` and `…/backup:local`.

Alpine and Debian packages are resolved from the pinned release repositories at build time, without
exact pins. **A real deployment should independently review and pin image digests and package
versions.**

## 5. File inventory

There are 1,952 lines of configuration, code and scripts, excluding docs and specs.

| Area | Files |
|---|---|
| Root | `README.md`, `BUILD_REPORT.md`, `docker-compose.yml`, `.gitignore`, `.dockerignore` |
| Spec | `specs/2026-10-31-legacy-web-hardening/{plan,requirements,validation}.md` |
| Edge | `docker/edge/{Dockerfile,nginx.conf,entrypoint.sh}` |
| Origin | `docker/origin/{Dockerfile,apache-vhost.conf,apache-hardening.conf,php-hardening.ini}` |
| Origin pages | `docker/origin/public/{index,health,session,lab-request-context}.php`, `docker/origin/public/static/lab-note.txt` |
| Origin code | `docker/origin/lib/lab.php`, `docker/origin/bin/{migrate,healthcheck}.php` |
| Backup | `docker/backup/{Dockerfile,backup-verify.sh}` |
| Tester | `docker/tester/{Dockerfile,run-acceptance.sh}` |
| Wrapper | `scripts/lab.ps1`: ASCII-only, `Set-StrictMode -Version Latest`, `$ErrorActionPreference='Stop'`, explicit exit-code checks |
| Docs | `tests/acceptance/README.md`, `artifacts/README.md` |

Three small refinements to the suggested structure, each documented in the spec:
- `docker/origin/lib/` holds shared PHP helpers outside the document root.
- `docker/origin/bin/healthcheck.php` is the container healthcheck.
- `docker/origin/public/static/` is an index-less folder that demonstrates disabled listing.

**Generated, local-only and Git-ignored:** `artifacts/evidence/**/*.log`, which is sanitized run
evidence. There are no certificates, keys, SQLite files, archives, `.env` files or `.runtime` in the
tree (V-HYG-01). At local build-report time, no `.git` directory existed. After the owner-authorized
publication, `.git/` is local version-control metadata, not a deliverable. Fixture data and backups
exist only in Docker named volumes, and the TLS key only on the edge's tmpfs.

## 6. Validation results

### 6.1 Required sequence (cycle 1, from a clean `reset -ConfirmLabReset`)

| # | Command | Exit | Result |
|---|---|---|---|
| 1 | `.\scripts\lab.ps1 up` | 0 | `PASS V-DATA-01`: fixture seeded (marker `LAB_BACKUP_FIXTURE=v1`, 3 items, schema 1, integrity ok); origin state mount read-only; `READY` |
| 2 | `.\scripts\lab.ps1 test` | 0 | **38 of 38 passed** (tester 25, host 13): `TEST OK` |
| 3 | `.\scripts\lab.ps1 backup` | 0 | `PASS V-BAK-01`, `PASS V-BAK-02` (gate refused before verification, exit 3) |
| 4 | `.\scripts\lab.ps1 verify-backup` | 0 | `PASS V-BAK-03`, `PASS V-BAK-04`, `PASS V-BAK-05` (gate passes) |
| 5 | `.\scripts\lab.ps1 migrate-status` | 0 | `PASS V-MIG-01` |
| 6 | `.\scripts\lab.ps1 migrate-dry-run` | 0 | `PASS V-MIG-02` |
| 7 | `.\scripts\lab.ps1 migrate-apply` | 0 | `PASS V-MIG-03`, `PASS V-MIG-04`, `PASS V-MIG-05` |
| 8 | `.\scripts\lab.ps1 rollback` | 0 | `PASS V-RB-01`, `PASS V-RB-02`, `PASS V-RB-03`, `PASS V-RB-04` |
| 9 | `.\scripts\lab.ps1 down` | 0 | `DOWN OK` (volumes kept) |

**Totals:**
- **Automated checks:** 53 passed, 0 failed. That's 38 acceptance checks plus 15 lifecycle checks.
- **Manual idempotency check:** V-OPS-02 passed (§6.3).
- **All 54 validation IDs** are satisfied.

**Acceptance test catalogue (38 in `test`):**

| Group | IDs | What they prove |
|---|---|---|
| Compose config | V-CFG-01..05 | Config valid; one port `127.0.0.1:8443→443` (edge only); origin has no ports and only `origin_net` (internal, `172.28.0.0/24`, static IPs); pinned tags only; helpers scoped, no bind mounts, origin state read-only |
| Runtime exposure | V-RUN-01..02 | `compose ps`: edge and origin running, origin healthy with no published port; `port edge 443` = `127.0.0.1:8443`; host listener on 8443 is `127.0.0.1` only |
| TLS | V-TLS-01..06 | A strict client rejects the self-signed certificate (curl exit 60); `-k` (lab only) gives 200; TLS 1.2 and 1.3 succeed; TLS 1.1 is refused by the edge (`alert protocol version`); the certificate is self-signed `CN=localhost` with SAN `DNS:localhost` and `IP:127.0.0.1`, valid 8 days or less |
| Edge | V-EDGE-01..10 | Exact warning on the landing page; nosniff, DENY, no-referrer and CSP headers each present once; no HSTS; `Server: nginx` only, no `X-Powered-By`; unexpected Host gets 421 **and its probe token never appears in the origin access log** (allowed-Host probe does); TRACE gets 405; POST, PUT, DELETE and OPTIONS get 405; index-less directory gets a generic 404; unknown path gets a generic 404 |
| Forwarding | V-FWD-01..03 | PHP sees `scheme=https`, `port=443`, `host=localhost`, `via_trusted_edge=true` and `client_ip` = the peer Nginx observed. Forged XFF, X-Real-IP, Forwarded, CF-Connecting-IP, True-Client-IP, X-Client-IP and X-Forwarded-* change nothing. Only the 7 documented fields are returned. |
| Origin restriction | V-ORIGIN-01..03 | Direct HTTP from `172.28.0.20` gets 403; direct with forged `X-Forwarded-For: 172.28.0.2` still gets 403; `/health` through the edge stays 200 |
| Session | V-SESS-01..04 | Exactly one cookie: `LABSESSID; path=/; secure; HttpOnly; SameSite=Lax`, with no Domain and no PHPSESSID; counter 1 → 2 with a jar; a client-chosen ID is replaced (strict mode); `Cache-Control: no-store` |
| Wrapper and docs | V-OPS-01, V-OPS-03, V-HYG-01, V-DOC-01..02 | Strict mode and `Stop` active, with exactly 10 commands; `reset` without the flag exits 2 and leaves the volumes untouched; clean tree; README warning, required sections, the Cloudflare-style label, and no un-negated claims |

### 6.2 Backup, migration and rollback evidence (cycle 1)

Values are from `artifacts/evidence/cycle1/*.log`, which is Git-ignored and disposable.

**Fixture:**
- seeded at schema version 1;
- live SHA-256 `2f9e7320…b1d1e`;
- data digest (marker + item rows) `a5e6c5e6085c4f1e…`.

**Backup:** archive `lab-backup-20261101T011945Z.tar.gz` (1,043 bytes) with a `.sha256` manifest.
- The live hash was stable across the snapshot, and the snapshot passed `integrity_check`.
- The previous evidence was invalidated.
- The gate then **refused** with exit 3: no verified evidence yet.

**Verify:**
- `sha256sum -c` passed, and the archive members were exactly `CONTENTS.sha256`, `backup-meta.env` and
  `lab.sqlite`.
- The restore went into a disposable `/tmp/restore.HjgFFE` inside the one-shot container, and the
  directory was removed afterwards.
- `CONTENTS.sha256` passed; integrity ok; marker `LAB_BACKUP_FIXTURE=v1`; 3 items; schema 1.
- The write probe proved the live mount is read-only.
- Evidence was written, and the gate then **passed**.

**Dry-run:**
- The disposable copy reached schema 2 with `lab_change_log` present, data digest unchanged and
  integrity ok.
- The **live SHA-256 was the same before and after** (`2f9e73205e23727d…`), and the live schema stayed 1.

**Apply:**
1. `GATE PASS` was printed **before any change**, evaluated under the write lock.
2. Schema moved from 1 to 2, `lab_change_log` was created, the data digest was unchanged, integrity ok,
   and a journal row was written. The new live SHA-256 was `02df8561…a399`.
3. A second `apply` reported `ALREADY APPLIED`, with the state line unchanged.
4. `/health` through the edge returned 200 `{"status":"ok"}`.

**Rollback:**
1. Schema moved from 2 to 1 and `lab_change_log` was dropped. The marker was intact, the **data digest
   equalled the digest recorded at apply**, and integrity was ok. The new live SHA-256 was `0723db57…9bee`.
2. `/health` through the edge returned 200.
3. A second `rollback` reported `NOTHING TO ROLL BACK`, with the state unchanged.
4. The gate then **refused** a new apply ("live fixture changed since the verified backup"), with
   remediation.

### 6.3 Idempotency and negative paths (cycle 2, V-OPS-02)

These runs started from the persisted volumes after `down`. Evidence is in `artifacts/evidence/cycle2/`.

| Step | Command | Exit | Observed |
|---|---|---|---|
| 1–2 | `up` twice (second while running) | 0, 0 | `FIXTURE verified-existing`; `UP OK` both times |
| 3 | `test` | 0 | 38 of 38 passed again |
| 4 | `migrate-apply` with no fresh verified backup | **1** | `GATE REFUSED: the live fixture changed since the verified backup was taken`, with the exact `REMEDIATION:` steps. No change made. |
| 5–8 | `backup`, `verify-backup`, `migrate-dry-run`, `migrate-apply` | 0 | All PASS (2 + 3 + 1 + 3 checks) |
| 9 | `rollback` | 0 | 4 checks passed |
| 10 | `rollback` again | 0 | `NOTHING TO ROLL BACK` twice; `SKIP V-RB-04` (nothing changed); V-RB-02 and V-RB-03 passed |
| 11 | `reset` (no flag) | **2** | `REFUSED` with the `-ConfirmLabReset` remediation. Nothing removed. |
| — | `down` twice | 0, 0 | `DOWN OK` both times. No containers remain, the named volumes are kept, and nothing listens on 8443. |

### 6.4 Explicit checks before declaring success

| Check | Result |
|---|---|
| `docker compose --profile tools config --quiet` | exit 0 |
| `docker compose ps` | `edge running 127.0.0.1:8443->443/tcp`; `origin running (healthy) 80/tcp`, exposed inside Docker only |
| `docker port <origin>` | none, so origin has no host-published port |
| `docker port <edge>` | `443/tcp -> 127.0.0.1:8443` only |
| Project tree | Source, docs, specs and `artifacts/evidence/**/*.log` only. No certificates, keys, SQLite files, archives, `.env`, `.runtime` or `.git`. Every source, config, spec and doc file uses LF line endings. Only the Git-ignored evidence logs written by PowerShell use CRLF. |
| Evidence secret scan | 0 matches for session-ID values, `PHPSESSID=`, PEM or private-key markers, `HTTP_COOKIE` and `DOCUMENT_ROOT` |
| Container log scan | Origin: 0 PHP warnings, notices, deprecations or fatals. Edge: 0 key, certificate or cookie strings; only the "generated ephemeral certificate" notice and minimal access lines. |

### 6.5 Defects found and fixed during implementation

These were caught by the checks and fixed in this project. No check was weakened or skipped.

1. **The request-context field didn't match how `mod_remoteip` behaves.** It consumes the forwarded
   entry, so the planned "hops = 1" was wrong. The field was renamed to `x_forwarded_for_unconsumed`,
   which must be 0. The spec was updated.
2. **V-EDGE-08 expected 403** but the deterministic behaviour is 404 without `mod_autoindex`. The spec
   and test now require exactly 404 with the generic body and no listing.
3. **The backup script exited 1 after a successful backup.** The EXIT trap referenced a function-local
   variable under `set -u`. It now uses a script-level scratch variable, and also asserts that the
   restore directory was removed.
4. **Rollback hit a `PDOException`.** An open SQLite `SELECT` statement blocked `DROP TABLE`. The
   transaction was safely reverted, leaving the fixture at schema 2. The statement is now finalized
   before the transaction, and error messages include the SQLSTATE code.
5. **Wrapper log noise:** BuildKit progress now uses `--progress quiet` in `up`.

## 7. Known limitations and non-claims

**What the lab doesn't prove:**
- RPO/RTO, encrypted, offsite or immutable backups, disaster recovery, production migration safety, or
  that live rollback is suitable.

**Gaps in the controls:**
- Static Compose IPs aren't strong identity: anything able to claim `172.28.0.2` on `origin_net` would
  be trusted.
- `edge_net` is a normal bridge network, because Docker can't publish ports from an `internal`
  network. So `edge` and `tester` could make outbound connections in principle; neither does.
- There's no authentication, CSRF protection (no forms), WAF, rate limiting, monitoring, or performance
  or load testing.
- The certificate is self-signed, so browsers warn. It's regenerated on every edge start.
- Base images are pinned by tag only, not by digest, and Alpine and Debian packages aren't pinned.
- The origin healthcheck logs one expected authz denial per probe (every 2 s at start, then every 60 s).
- TLS 1.1 refusal was proven with an OpenSSL client forced to `SECLEVEL=0`. Older protocols (SSLv3,
  TLS 1.0) weren't probed separately.

**Non-claims:** this lab is not production-ready, not fully secure, not Cloudflare-protected, not
compliant with PCI DSS, SOC 2, HIPAA or any other framework, not certified, and not suitable for client
data. No Cloudflare product, account or network was used.

## 8. Actions not taken during the local build and validation phase

During the local build and validation phase, this task did **not**:
- initialize Git, commit, push, add a remote, create a GitHub repository, or modify any other repository;
- deploy anything, bind a public interface, open a tunnel, configure DNS, or contact Cloudflare;
- use any real client domain, credential, certificate, backup, IP address, configuration, dataset, user
  record, cookie, secret or personal information. All data is synthetic and fictional, and the
  certificate is ephemeral and self-signed;
- use an end-of-life PHP runtime or a floating `latest` image tag;
- publish the Apache origin port, or expose any host port other than `127.0.0.1:8443`;
- run a global Docker cleanup (`system prune`, `volume prune`), or remove resources outside the
  `legacy-web-hardening-lab` Compose project. `reset -ConfirmLabReset` was used once, to start the
  recorded validation from a clean lab state, and it removed only this project's containers, networks
  and two named volumes.

**External network use:** read-only Docker Hub tag lookups to choose image versions, image pulls, and
Alpine and Debian package downloads during `docker build`. The lab application itself made **no**
outbound calls: `origin_net` is internal, and `backup` and `migrator` run with no network.

**State left on this machine:**
- The lab is **down**, with no containers or project networks and nothing listening on 8443.
- The named volumes `legacy-web-hardening-lab_legacy_state` and `legacy-web-hardening-lab_lab_backups`
  are kept. They hold synthetic data only. Delete them with `.\scripts\lab.ps1 reset -ConfirmLabReset`.
- The locally built images `legacy-web-hardening-lab/*:local` and the three pulled base images remain.
