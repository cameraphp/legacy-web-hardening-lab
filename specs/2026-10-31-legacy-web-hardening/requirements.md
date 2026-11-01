# Requirements — legacy-web-hardening-lab (2026-10-31)

IDs are stable. Read "must" as mandatory. Every requirement maps to at least one validation ID in
[`validation.md`](./validation.md). The mapping table is at the end of this file.

## Safety and scope

| ID | Requirement |
|---|---|
| REQ-SAFE-001 | The lab must be local-only. No service may bind a non-loopback host interface. The lab application must not call any external API. There must be no DNS, tunnel, Cloudflare or deployment activity. |
| REQ-SAFE-002 | Only synthetic fixture data may be used. The landing page and `README.md` must show the exact warning: `LAB ONLY — fictional local hardening demonstration; do not use with client data or production systems.` |
| REQ-SAFE-003 | No private key, certificate, session ID, environment dump, SQLite file or backup archive may be stored in the project tree, test evidence or reports. Generated local artifacts must be Git-ignored. |
| REQ-SAFE-004 | Documentation must keep demonstrated lab controls separate from production non-claims. It must not claim production readiness, full security, Cloudflare protection, compliance or suitability for client data. |

## Architecture

| ID | Requirement |
|---|---|
| REQ-ARCH-001 | A single `docker-compose.yml` with project name `legacy-web-hardening-lab` must define the services `edge`, `origin`, `tester`, `backup` and `migrator`. It must define the networks `edge_net` (bridge) and `origin_net` (`internal: true`, `172.28.0.0/24`), with static `origin_net` IPs: edge `172.28.0.2`, origin `172.28.0.10`, tester `172.28.0.20`. |
| REQ-ARCH-002 | Exactly one host-published port must exist: `edge` on `127.0.0.1:8443 → 443`. |
| REQ-ARCH-003 | `origin` must have no `ports:` declaration and must attach only to `origin_net`. |
| REQ-ARCH-004 | Every image must use an explicit pinned tag (no `latest`). PHP must be a supported line (8.5.x). The documentation must recommend digest pinning for any real deployment. |
| REQ-ARCH-005 | The one-shot helpers must be scoped. `tester` joins Compose networks only and has no host port. `backup` and `migrator` use `network_mode: none` and named volumes only, with no host bind mounts. |

## Edge

| ID | Requirement |
|---|---|
| REQ-EDGE-001 | TLS must terminate at the edge. The certificate must be an ephemeral self-signed one (CN/SAN `localhost`, SAN `127.0.0.1`) generated at container start on `tmpfs`. Only TLS 1.2 and 1.3 are allowed. A strict client must reject the certificate, and the tester may bypass verification only explicitly (`-k`). |
| REQ-EDGE-002 | A default server must reject unexpected `Host` values with a deterministic `421`. Such requests must not reach the origin. Allowed names: `localhost`, `127.0.0.1`. |
| REQ-EDGE-003 | Responses must carry `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer` and a conservative CSP (`default-src 'none'` …). HSTS must be omitted deliberately, with the reason documented. |
| REQ-EDGE-004 | Server version disclosure must be minimized: `server_tokens off`, so the response carries only `Server: nginx`. There must be no `X-Powered-By` header and no Apache or PHP version strings. |
| REQ-EDGE-005 | Only `GET` and `HEAD` are allowed. `TRACE` and other methods must return `405`. |
| REQ-EDGE-006 | Directory listing must be disabled, and error responses must be generic (no version, path or stack). |
| REQ-EDGE-007 | The design must be labelled **Cloudflare-style edge/origin separation and header sanitation only**, implying no Cloudflare product or protection. |

## Forwarded headers and trusted proxy

| ID | Requirement |
|---|---|
| REQ-FWD-001 | The edge must forward only allowlisted request headers. Client-supplied `Forwarded`, `X-Forwarded-*`, `X-Real-IP`, `CF-Connecting-IP`, `True-Client-IP` and similar headers must never reach the origin. |
| REQ-FWD-002 | The edge must rebuild the forwarding headers by overwriting, not appending: `X-Forwarded-For` and `X-Real-IP` set to the client address Nginx observed, `X-Forwarded-Proto: https`, `X-Forwarded-Port: 443` and `X-Forwarded-Host` set to the matched allowlisted host. |
| REQ-FWD-003 | Apache `mod_remoteip` must trust only `172.28.0.2` (`RemoteIPInternalProxy`). `HTTPS=on` may be set only when the connection peer is the edge and it sent `X-Forwarded-Proto: https`. No inbound header may control the client IP, scheme, host or port that PHP reports. |
| REQ-FWD-004 | `/lab/request-context` must return only fixed, sanitized fields. It must never return environment variables, filesystem paths, secrets, full headers or configuration. |

## Origin

| ID | Requirement |
|---|---|
| REQ-ORIGIN-001 | Apache must listen only on internal port 80 (no TLS listener). Requests must be allowed only when the TCP connection peer is `172.28.0.2` (`Require expr "%{CONN_REMOTE_ADDR} == '172.28.0.2'"`). The documentation must explain why plain `Require ip` is unsuitable once `mod_remoteip` is active. |
| REQ-ORIGIN-002 | Apache hardening: `autoindex` and `status` disabled, `Options -Indexes`, `AllowOverride None`, `TraceEnable Off`, `ServerTokens Prod`, `ServerSignature Off`, generic `ErrorDocument`s, `X-Powered-By` unset. |
| REQ-ORIGIN-003 | PHP hardening: `expose_php=Off`, `display_errors=Off`, `allow_url_fopen=Off`, `allow_url_include=Off`, `open_basedir` (Apache), and process-execution functions disabled. |
| REQ-ORIGIN-004 | Endpoints must be `/` (landing page with warning), `/health` (minimal: `{"status":"ok"}` or `503`), `/session` (lab session counter) and `/lab/request-context`. |

## Session and cookie

| ID | Requirement |
|---|---|
| REQ-SESSION-001 | `/session` must set exactly one cookie: a host-only `LABSESSID` with `Secure`, `HttpOnly`, `SameSite=Lax` and `path=/`, with no `Domain` and no `PHPSESSID`. |
| REQ-SESSION-002 | Session settings: `session.use_only_cookies=1`, `session.use_strict_mode=1`, `session.use_trans_sid=0`. An unknown, client-chosen session ID must be replaced with a new one. |
| REQ-SESSION-003 | Session responses must not be cacheable (`Cache-Control: no-store`). |
| REQ-SESSION-004 | A cookie jar must keep the session counter across requests (1, then 2). |

## Data, backup, migration, rollback

| ID | Requirement |
|---|---|
| REQ-DATA-001 | A synthetic SQLite fixture must live in the named volume `legacy_state`. `migrator init` must seed it idempotently with the marker `LAB_BACKUP_FIXTURE=v1`, 3 fictional items and schema version 1. `origin` must mount the state read-only. |
| REQ-BACKUP-001 | `backup create` must produce `lab-backup-<UTC>.tar.gz` plus a SHA-256 manifest in `lab_backups` from a consistent snapshot (live hash stable, snapshot `integrity_check` ok). It must invalidate earlier verification evidence and keep the newest 5 archives. |
| REQ-BACKUP-002 | `backup verify` must check the manifest and the archive member names, then restore into a separate disposable directory in the one-shot container, never over the live volume (which is mounted read-only). It must confirm integrity, marker, item count and schema, and write `verified/latest.json`. |
| REQ-MIGRATE-001 | `migrator` must provide `init`, `status`, `dry-run`, `apply`, `rollback` and `gate-check`, record events in `lab_migration_journal`, and use exit codes 0 ok, 2 usage, 3 gate refused, 4 precondition or integrity failure. |
| REQ-MIGRATE-002 | `dry-run` must apply the migration only to a disposable copy and must leave the live SHA-256 and schema version unchanged. |
| REQ-MIGRATE-003 | `apply` must refuse (exit 3, with a precise remediation message) unless current verification evidence exists, the archive checksum matches, and the evidence's live SHA-256 equals the current live DB. The gate result must be printed before any change. |
| REQ-MIGRATE-004 | `apply` must move the schema from version 1 to 2 (`lab_change_log`) in one transaction while preserving the data digest. Running it again must be a no-op. |
| REQ-ROLLBACK-001 | `rollback` must revert only migration `002` (schema 2 → 1), preserve the fixture marker and data digest, pass `integrity_check`, leave `/health` healthy through the edge, and be a no-op when run again. |
| REQ-ROLLBACK-002 | The documentation must describe the lab rollback procedures (migration rollback, service down/up, fixture rebuild) and that the lab has no "restore over live" path. |

## Operations, tests and documentation

| ID | Requirement |
|---|---|
| REQ-OPS-001 | `scripts/lab.ps1` must be the only Windows-facing wrapper. It must use `Set-StrictMode -Version Latest` and `$ErrorActionPreference='Stop'`, check native exit codes, and offer only `up`, `test`, `backup`, `verify-backup`, `migrate-status`, `migrate-dry-run`, `migrate-apply`, `rollback`, `down` and `reset`. |
| REQ-OPS-002 | Re-running the normal lifecycle must be idempotent, or must fail with a precise remediation message. |
| REQ-OPS-003 | `reset` must be destructive only with `-ConfirmLabReset`, and may remove only this Compose project's containers, networks and named volumes. No global Docker prune is allowed. |
| REQ-TEST-001 | Acceptance tests must run in containers. The only host prerequisites are Docker Desktop and PowerShell (no host curl, PHP, Apache, Nginx, Bash or OpenSSL). Test output must not include session IDs, keys or full cookie or header values. |
| REQ-DOC-001 | `README.md` must cover: the warning, architecture and trust boundaries, prerequisites, quick start and the expected browser warning, control behaviour, what the lab demonstrates and what it doesn't, tests, troubleshooting, safe shutdown, the reset warning, and a "before adapting elsewhere" checklist. `BUILD_REPORT.md` must record versions, inventory, results, evidence, limits and the actions not taken. |

## Requirement → validation mapping

| Requirement | Validation IDs |
|---|---|
| REQ-SAFE-001 | V-CFG-02, V-RUN-01, V-RUN-02, V-CFG-05 |
| REQ-SAFE-002 | V-EDGE-01, V-DOC-01 |
| REQ-SAFE-003 | V-HYG-01, V-TLS-06, V-SESS-01 |
| REQ-SAFE-004 | V-DOC-02 |
| REQ-ARCH-001 | V-CFG-01, V-CFG-03 |
| REQ-ARCH-002 | V-CFG-02, V-RUN-01, V-RUN-02 |
| REQ-ARCH-003 | V-CFG-03, V-RUN-01 |
| REQ-ARCH-004 | V-CFG-04 |
| REQ-ARCH-005 | V-CFG-05 |
| REQ-EDGE-001 | V-TLS-01, V-TLS-02, V-TLS-03, V-TLS-04, V-TLS-05, V-TLS-06 |
| REQ-EDGE-002 | V-EDGE-05, V-EDGE-10 |
| REQ-EDGE-003 | V-EDGE-02, V-EDGE-03 |
| REQ-EDGE-004 | V-EDGE-04 |
| REQ-EDGE-005 | V-EDGE-06, V-EDGE-07 |
| REQ-EDGE-006 | V-EDGE-08, V-EDGE-09 |
| REQ-EDGE-007 | V-DOC-02 |
| REQ-FWD-001 | V-FWD-02 |
| REQ-FWD-002 | V-FWD-01, V-FWD-02 |
| REQ-FWD-003 | V-FWD-01, V-FWD-02, V-ORIGIN-02 |
| REQ-FWD-004 | V-FWD-03 |
| REQ-ORIGIN-001 | V-ORIGIN-01, V-ORIGIN-02, V-ORIGIN-03 |
| REQ-ORIGIN-002 | V-EDGE-04, V-EDGE-06, V-EDGE-08, V-EDGE-09 |
| REQ-ORIGIN-003 | V-EDGE-04, V-FWD-03 |
| REQ-ORIGIN-004 | V-EDGE-01, V-ORIGIN-03, V-SESS-02, V-FWD-01 |
| REQ-SESSION-001 | V-SESS-01 |
| REQ-SESSION-002 | V-SESS-03 |
| REQ-SESSION-003 | V-SESS-04 |
| REQ-SESSION-004 | V-SESS-02 |
| REQ-DATA-001 | V-DATA-01 |
| REQ-BACKUP-001 | V-BAK-01, V-BAK-02 |
| REQ-BACKUP-002 | V-BAK-03, V-BAK-04, V-BAK-05 |
| REQ-MIGRATE-001 | V-MIG-01 |
| REQ-MIGRATE-002 | V-MIG-02 |
| REQ-MIGRATE-003 | V-BAK-02, V-BAK-05, V-MIG-03, V-RB-04 |
| REQ-MIGRATE-004 | V-MIG-03, V-MIG-04, V-MIG-05 |
| REQ-ROLLBACK-001 | V-RB-01, V-RB-02, V-RB-03 |
| REQ-ROLLBACK-002 | V-DOC-02 |
| REQ-OPS-001 | V-OPS-01 |
| REQ-OPS-002 | V-OPS-02 |
| REQ-OPS-003 | V-OPS-03 |
| REQ-TEST-001 | V-OPS-01, V-SESS-01 |
| REQ-DOC-001 | V-DOC-01, V-DOC-02 |
