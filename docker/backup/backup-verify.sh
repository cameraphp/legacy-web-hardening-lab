#!/usr/bin/env bash
# LAB ONLY: fixture-only backup creation and isolated restore verification.
# Requirements: REQ-BACKUP-001, REQ-BACKUP-002.
#   create : consistent snapshot -> archive + SHA-256 manifest; invalidates earlier evidence.
#   verify : manifest check -> restore into a disposable /tmp/restore.* directory -> integrity,
#            marker and state checks -> writes verified/latest.json.
# The live state volume is mounted READ-ONLY here, so a restore can never overwrite live data.
# This exercise does not prove RPO/RTO, encryption, offsite copies or disaster recovery.
set -Eeuo pipefail
umask 027

STATE_DB=/lab/state/lab.sqlite
ARCHIVES=/lab/backups/archives
VERIFIED=/lab/backups/verified
EVIDENCE="$VERIFIED/latest.json"
MARKER='LAB_BACKUP_FIXTURE=v1'
EXPECTED_ITEMS=3
KEEP=5
NAME_RE='^lab-backup-[0-9]{8}T[0-9]{6}Z\.tar\.gz$'

# Disposable working directory (script-level so the EXIT trap can still see it after a function returns).
SCRATCH=""
cleanup() { if [ -n "$SCRATCH" ]; then rm -rf "$SCRATCH"; fi; }
trap cleanup EXIT

die() {
  echo "ERROR: $1"
  if [ -n "${2:-}" ]; then echo "REMEDIATION: $2"; fi
  exit "${3:-4}"
}
sha() { sha256sum "$1" | cut -d' ' -f1; }
q() { sqlite3 -readonly -batch -noheader "$1" "$2"; }

create() {
  [ -f "$STATE_DB" ] || die "live fixture not found" 'Run .\scripts\lab.ps1 up first.'
  mkdir -p "$ARCHIVES" "$VERIFIED"
  local ts name work live_before live_after marker items schema
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  name="lab-backup-$ts.tar.gz"
  [ ! -e "$ARCHIVES/$name" ] || die "archive $name already exists" 'Wait one second and run backup again.'
  work=$(mktemp -d /tmp/backup.XXXXXX)
  SCRATCH=$work

  live_before=$(sha "$STATE_DB")
  sqlite3 -readonly "$STATE_DB" ".backup '$work/lab.sqlite'"
  live_after=$(sha "$STATE_DB")
  [ "$live_before" = "$live_after" ] || die "live fixture changed during the snapshot" 'Stop other lab operations and run backup again.'
  [ "$(q "$work/lab.sqlite" 'PRAGMA integrity_check;')" = "ok" ] || die "snapshot integrity_check failed"
  marker=$(q "$work/lab.sqlite" "SELECT value FROM lab_meta WHERE key='fixture_marker';")
  [ "$marker" = "$MARKER" ] || die "fixture marker missing from the snapshot"
  items=$(q "$work/lab.sqlite" 'SELECT COUNT(*) FROM lab_items;')
  schema=$(q "$work/lab.sqlite" 'PRAGMA user_version;')

  cat > "$work/backup-meta.env" <<EOF
FIXTURE_MARKER=$marker
SCHEMA_VERSION=$schema
ITEM_COUNT=$items
LIVE_DB_SHA256=$live_before
CREATED_UTC=$ts
EOF
  (cd "$work" && sha256sum lab.sqlite backup-meta.env > CONTENTS.sha256)
  tar -czf "$ARCHIVES/$name.partial" -C "$work" lab.sqlite backup-meta.env CONTENTS.sha256
  mv "$ARCHIVES/$name.partial" "$ARCHIVES/$name"
  (cd "$ARCHIVES" && sha256sum "$name" > "$name.sha256")
  printf '%s\n' "$name" > "$ARCHIVES/LATEST.tmp"
  mv "$ARCHIVES/LATEST.tmp" "$ARCHIVES/LATEST"

  # A new backup always invalidates earlier verification evidence: it has to be verified again.
  rm -f "$EVIDENCE"

  # Retention: keep the newest $KEEP archives, inside this lab's backup volume only.
  { ls -1 "$ARCHIVES" | grep -E "$NAME_RE" | sort -r | tail -n +$((KEEP + 1)) || true; } | while read -r old; do
    rm -f "$ARCHIVES/$old" "$ARCHIVES/$old.sha256"
  done

  echo "ARCHIVE $name ($(wc -c < "$ARCHIVES/$name") bytes), manifest $name.sha256, sha256=$(sha "$ARCHIVES/$name" | cut -c1-16)..."
  echo "PASS V-BAK-01 backup created: archive and SHA-256 manifest present; live sha256 stable across snapshot; snapshot integrity=ok; schema_version=$schema items=$items; previous evidence invalidated"
}

verify() {
  [ -f "$ARCHIVES/LATEST" ] || die "no backup archive found" 'Run .\scripts\lab.ps1 backup first.'
  local name members archive_sha restore meta_marker meta_schema meta_items meta_live marker items schema
  name=$(head -n1 "$ARCHIVES/LATEST")
  [[ "$name" =~ $NAME_RE ]] || die "LATEST pointer is invalid" 'Run .\scripts\lab.ps1 backup again.'
  [ -f "$ARCHIVES/$name" ] && [ -f "$ARCHIVES/$name.sha256" ] || die "archive or manifest missing" 'Run .\scripts\lab.ps1 backup again.'
  (cd "$ARCHIVES" && sha256sum -c "$name.sha256" >/dev/null 2>&1) || die "archive checksum mismatch for $name" 'Discard it and run .\scripts\lab.ps1 backup again.'
  members=$(tar -tzf "$ARCHIVES/$name" | sort | tr '\n' ' ')
  [ "$members" = "CONTENTS.sha256 backup-meta.env lab.sqlite " ] || die "unexpected archive members"
  archive_sha=$(sha "$ARCHIVES/$name")
  echo "PASS V-BAK-03 manifest verified: sha256sum -c ok for $name; members exactly CONTENTS.sha256 backup-meta.env lab.sqlite"

  restore=$(mktemp -d /tmp/restore.XXXXXX)
  SCRATCH=$restore
  case "$restore" in /tmp/restore.*) ;; *) die "unexpected restore target $restore" ;; esac
  tar -xzf "$ARCHIVES/$name" -C "$restore"
  (cd "$restore" && sha256sum -c CONTENTS.sha256 >/dev/null 2>&1) || die "restored contents checksum mismatch"

  meta() { grep -E "^$1=" "$restore/backup-meta.env" | head -n1 | cut -d= -f2-; }
  meta_marker=$(meta FIXTURE_MARKER)
  meta_schema=$(meta SCHEMA_VERSION)
  meta_items=$(meta ITEM_COUNT)
  meta_live=$(meta LIVE_DB_SHA256)
  [[ "$meta_schema" =~ ^[0-9]+$ && "$meta_items" =~ ^[0-9]+$ && "$meta_live" =~ ^[0-9a-f]{64}$ ]] || die "backup metadata is malformed"

  [ "$(q "$restore/lab.sqlite" 'PRAGMA integrity_check;')" = "ok" ] || die "restored database integrity_check failed"
  marker=$(q "$restore/lab.sqlite" "SELECT value FROM lab_meta WHERE key='fixture_marker';")
  items=$(q "$restore/lab.sqlite" 'SELECT COUNT(*) FROM lab_items;')
  schema=$(q "$restore/lab.sqlite" 'PRAGMA user_version;')
  [ "$marker" = "$MARKER" ] && [ "$marker" = "$meta_marker" ] || die "fixture marker mismatch in restore"
  [ "$items" = "$EXPECTED_ITEMS" ] && [ "$items" = "$meta_items" ] || die "item count mismatch in restore"
  [ "$schema" = "$meta_schema" ] || die "schema version mismatch in restore"

  # Prove the live state mount can't be written from here (restore never targets live data).
  if touch /lab/state/.lab-write-probe 2>/dev/null; then
    rm -f /lab/state/.lab-write-probe
    die "live state mount is writable from the backup container"
  fi
  echo "PASS V-BAK-04 isolated restore verified in disposable $restore: CONTENTS.sha256 ok; integrity=ok; marker=$MARKER; items=$items; schema_version=$schema; live mount read-only=yes"

  mkdir -p "$VERIFIED"
  printf '{"status":"verified","archive":"%s","archive_sha256":"%s","live_db_sha256":"%s","schema_version":%s,"fixture_marker":"%s","item_count":%s,"verified_utc":"%s"}\n' \
    "$name" "$archive_sha" "$meta_live" "$schema" "$MARKER" "$items" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$EVIDENCE.tmp"
  mv "$EVIDENCE.tmp" "$EVIDENCE"
  rm -rf "$restore"
  SCRATCH=""
  [ ! -e "$restore" ] || die "disposable restore directory was not removed"
  echo "EVIDENCE written: verified/latest.json (archive=$name); disposable restore directory removed"
}

case "${1:-}" in
  create) create ;;
  verify) verify ;;
  *) echo "usage: backup-verify create|verify"; exit 2 ;;
esac
