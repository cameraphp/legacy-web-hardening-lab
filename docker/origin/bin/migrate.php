<?php
// LAB ONLY: migration control for the synthetic SQLite fixture (REQ-DATA-001, REQ-MIGRATE-001..004,
// REQ-ROLLBACK-001). Runs only in the one-shot "migrator" container (network_mode: none).
// Commands: init | status | dry-run | apply | rollback | gate-check
// Exit codes: 0 ok, 2 usage, 3 gate refused, 4 precondition or integrity failure.
// Output is ASCII-only and contains no secrets: hashes of synthetic data, counts and versions.
declare(strict_types=1);

const DB_PATH = '/var/lib/lab/state/lab.sqlite';
const ARCHIVE_DIR = '/lab/backups/archives';
const EVIDENCE_PATH = '/lab/backups/verified/latest.json';
const MARKER = 'LAB_BACKUP_FIXTURE=v1';
const MIGRATION_ID = '002_lab_change_log';
const BASE_VERSION = 1;
const TARGET_VERSION = 2;
const EXPECTED_ITEMS = 3;
const ARCHIVE_NAME_RE = '/^lab-backup-\d{8}T\d{6}Z\.tar\.gz$/';
const HEX64_RE = '/^[0-9a-f]{64}$/';

const EXIT_OK = 0;
const EXIT_USAGE = 2;
const EXIT_GATE = 3;
const EXIT_PRECONDITION = 4;

const REMEDIATION_GATE = 'Run .\scripts\lab.ps1 backup, then .\scripts\lab.ps1 verify-backup, then retry .\scripts\lab.ps1 migrate-apply.';

/** Migration 002 (up): a reversible, lab-only metadata table. */
const MIGRATION_UP_SQL = [
    'CREATE TABLE lab_change_log (id INTEGER PRIMARY KEY, note TEXT NOT NULL, recorded_utc TEXT NOT NULL)',
    "INSERT INTO lab_change_log (note, recorded_utc) VALUES ('Synthetic lab migration 002 applied', :now)",
];
/** Migration 002 (down). */
const MIGRATION_DOWN_SQL = ['DROP TABLE lab_change_log'];

function out(string $line): void
{
    fwrite(STDOUT, $line . PHP_EOL);
}

function fail(int $code, string $message, string $remediation = ''): never
{
    out('ERROR: ' . $message);
    if ($remediation !== '') {
        out('REMEDIATION: ' . $remediation);
    }
    exit($code);
}

function now_utc(): string
{
    return gmdate('Y-m-d\TH:i:s\Z');
}

function open_db(string $path, bool $readonly): Pdo\Sqlite
{
    $pdo = new Pdo\Sqlite('sqlite:' . $path, null, null, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        Pdo\Sqlite::ATTR_OPEN_FLAGS => $readonly ? Pdo\Sqlite::OPEN_READONLY : Pdo\Sqlite::OPEN_READWRITE,
    ]);
    $pdo->exec('PRAGMA busy_timeout = 5000');
    return $pdo;
}

function require_fixture(): void
{
    if (!is_file(DB_PATH)) {
        fail(EXIT_PRECONDITION, 'synthetic fixture not found', 'Run .\scripts\lab.ps1 up (it runs "migrator init").');
    }
}

function live_sha256(): string
{
    clearstatcache(true, DB_PATH);
    return (string) hash_file('sha256', DB_PATH);
}

function schema_version(Pdo\Sqlite $pdo): int
{
    return (int) $pdo->query('PRAGMA user_version')->fetchColumn();
}

function table_exists(Pdo\Sqlite $pdo, string $name): bool
{
    $stmt = $pdo->prepare("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = :n");
    $stmt->execute([':n' => $name]);
    return (int) $stmt->fetchColumn() === 1;
}

function fixture_marker(Pdo\Sqlite $pdo): string
{
    return (string) $pdo->query("SELECT value FROM lab_meta WHERE key = 'fixture_marker'")->fetchColumn();
}

function item_count(Pdo\Sqlite $pdo): int
{
    return (int) $pdo->query('SELECT COUNT(*) FROM lab_items')->fetchColumn();
}

function integrity_ok(Pdo\Sqlite $pdo): bool
{
    return $pdo->query('PRAGMA integrity_check')->fetchColumn() === 'ok';
}

/** Digest of the fixture marker and every item row: proves rollback preserved data integrity. */
function data_digest(Pdo\Sqlite $pdo): string
{
    $buffer = fixture_marker($pdo) . "\n";
    foreach ($pdo->query('SELECT id, label, category FROM lab_items ORDER BY id') as $row) {
        $buffer .= $row['id'] . '|' . $row['label'] . '|' . $row['category'] . "\n";
    }
    return hash('sha256', $buffer);
}

function state_line(): void
{
    $pdo = open_db(DB_PATH, true);
    out('STATE schema_version=' . schema_version($pdo) . ' live_sha256=' . live_sha256());
}

/**
 * Verified-backup gate (REQ-MIGRATE-003).
 * @return array{0: bool, 1: string, 2: ?string} [passed, reason, archive]
 */
function evaluate_gate(): array
{
    if (!is_file(EVIDENCE_PATH)) {
        return [false, 'no verified backup evidence found (verified/latest.json is missing)', null];
    }
    try {
        $evidence = json_decode((string) file_get_contents(EVIDENCE_PATH), true, 8, JSON_THROW_ON_ERROR);
    } catch (Throwable) {
        return [false, 'backup evidence is not valid JSON', null];
    }
    if (!is_array($evidence) || ($evidence['status'] ?? null) !== 'verified') {
        return [false, 'backup evidence does not report status=verified', null];
    }
    $archive = $evidence['archive'] ?? '';
    if (!is_string($archive) || preg_match(ARCHIVE_NAME_RE, $archive) !== 1) {
        return [false, 'backup evidence names an invalid archive', null];
    }
    $archiveSha = $evidence['archive_sha256'] ?? '';
    $liveAtBackup = $evidence['live_db_sha256'] ?? '';
    if (!is_string($archiveSha) || preg_match(HEX64_RE, $archiveSha) !== 1
        || !is_string($liveAtBackup) || preg_match(HEX64_RE, $liveAtBackup) !== 1) {
        return [false, 'backup evidence has malformed checksums', null];
    }
    $archivePath = ARCHIVE_DIR . '/' . $archive;
    if (!is_file($archivePath) || !is_file($archivePath . '.sha256')) {
        return [false, "verified archive $archive or its manifest is missing", null];
    }
    if (hash_file('sha256', $archivePath) !== $archiveSha) {
        return [false, "verified archive $archive no longer matches its recorded checksum", null];
    }
    $manifestSha = strtok((string) file_get_contents($archivePath . '.sha256'), " \t\n");
    if ($manifestSha !== $archiveSha) {
        return [false, "manifest for $archive does not match the verification evidence", null];
    }
    if (live_sha256() !== $liveAtBackup) {
        return [false, 'the live fixture changed since the verified backup was taken', null];
    }
    return [true, "verified backup $archive matches the current live fixture", $archive];
}

function cmd_init(): int
{
    $seeded = false;
    if (!is_file(DB_PATH)) {
        $tmp = dirname(DB_PATH) . '/.lab.sqlite.tmp-' . bin2hex(random_bytes(4));
        $pdo = new Pdo\Sqlite('sqlite:' . $tmp, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        $pdo->exec('BEGIN IMMEDIATE');
        $pdo->exec('CREATE TABLE lab_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        $pdo->exec('CREATE TABLE lab_items (id INTEGER PRIMARY KEY, label TEXT NOT NULL, category TEXT NOT NULL)');
        $pdo->exec('CREATE TABLE lab_migration_journal (id INTEGER PRIMARY KEY AUTOINCREMENT, migration TEXT NOT NULL,'
            . ' action TEXT NOT NULL, schema_before INTEGER NOT NULL, schema_after INTEGER NOT NULL,'
            . ' data_digest TEXT NOT NULL, backup_archive TEXT, recorded_utc TEXT NOT NULL)');
        $meta = $pdo->prepare('INSERT INTO lab_meta (key, value) VALUES (:k, :v)');
        $meta->execute([':k' => 'fixture_marker', ':v' => MARKER]);
        $meta->execute([':k' => 'fixture_note', ':v' => 'Synthetic, fictional lab data only.']);
        $item = $pdo->prepare('INSERT INTO lab_items (id, label, category) VALUES (:id, :label, :category)');
        foreach ([[1, 'Fictional widget A', 'demo'], [2, 'Fictional widget B', 'demo'], [3, 'Fictional archive record', 'demo']] as [$id, $label, $category]) {
            $item->execute([':id' => $id, ':label' => $label, ':category' => $category]);
        }
        $pdo->exec('PRAGMA user_version = ' . BASE_VERSION);
        $pdo->exec('COMMIT');
        $pdo = null;
        chmod($tmp, 0644);
        if (!rename($tmp, DB_PATH)) {
            fail(EXIT_PRECONDITION, 'could not move the seeded fixture into place');
        }
        $seeded = true;
    }
    $pdo = open_db(DB_PATH, true);
    $marker = fixture_marker($pdo);
    $items = item_count($pdo);
    $version = schema_version($pdo);
    if ($marker !== MARKER || $items !== EXPECTED_ITEMS || !in_array($version, [BASE_VERSION, TARGET_VERSION], true) || !integrity_ok($pdo)) {
        fail(EXIT_PRECONDITION, 'existing fixture failed verification (marker, item count, schema or integrity)',
            'Inspect the lab state; to rebuild it run .\scripts\lab.ps1 reset -ConfirmLabReset, then up.');
    }
    out(sprintf('FIXTURE %s: marker=%s items=%d schema_version=%d integrity=ok',
        $seeded ? 'seeded' : 'verified-existing', MARKER, $items, $version));
    state_line();
    return EXIT_OK;
}

function cmd_status(): int
{
    require_fixture();
    $pdo = open_db(DB_PATH, true);
    [$gateOk, $gateReason] = evaluate_gate();
    out('schema_version=' . schema_version($pdo));
    out('fixture_marker=' . fixture_marker($pdo));
    out('items=' . item_count($pdo));
    out('lab_change_log_present=' . (table_exists($pdo, 'lab_change_log') ? 'yes' : 'no'));
    out('data_digest=' . substr(data_digest($pdo), 0, 16) . '...');
    out('live_sha256=' . substr(live_sha256(), 0, 16) . '...');
    out('integrity=' . (integrity_ok($pdo) ? 'ok' : 'FAILED'));
    out('gate=' . ($gateOk ? 'PASS' : 'REFUSED') . ' (' . $gateReason . ')');
    out('journal (last 5):');
    $rows = $pdo->query('SELECT migration, action, schema_before, schema_after, recorded_utc FROM lab_migration_journal ORDER BY id DESC LIMIT 5')->fetchAll(PDO::FETCH_ASSOC);
    if ($rows === []) {
        out('  (empty)');
    }
    foreach ($rows as $r) {
        out(sprintf('  %s %s %d->%d %s', $r['migration'], $r['action'], $r['schema_before'], $r['schema_after'], $r['recorded_utc']));
    }
    out('PASS V-MIG-01 status reported: schema version, marker, items, digest, live sha256, gate state, journal');
    state_line();
    return EXIT_OK;
}

function cmd_gate_check(): int
{
    require_fixture();
    [$ok, $reason] = evaluate_gate();
    if ($ok) {
        out('GATE PASS: ' . $reason);
        return EXIT_OK;
    }
    out('GATE REFUSED: ' . $reason);
    out('REMEDIATION: ' . REMEDIATION_GATE);
    return EXIT_GATE;
}

/** Applies migration 002 inside an already-open transaction. */
function migrate_up(Pdo\Sqlite $pdo): void
{
    foreach (MIGRATION_UP_SQL as $sql) {
        if (str_contains($sql, ':now')) {
            $stmt = $pdo->prepare($sql);
            $stmt->execute([':now' => now_utc()]);
        } else {
            $pdo->exec($sql);
        }
    }
    $pdo->exec('PRAGMA user_version = ' . TARGET_VERSION);
}

function cmd_dry_run(): int
{
    require_fixture();
    $before = live_sha256();
    $live = open_db(DB_PATH, true);
    $version = schema_version($live);
    $digest = data_digest($live);
    $live = null;
    if ($version === TARGET_VERSION) {
        out('NO-OP: migration ' . MIGRATION_ID . ' is already applied (schema_version=2); nothing to dry-run.');
        if (live_sha256() !== $before) {
            fail(EXIT_PRECONDITION, 'live fixture changed during a no-op dry-run');
        }
        out('PASS V-MIG-02 dry-run no-op: live sha256 unchanged, schema_version=2');
        state_line();
        return EXIT_OK;
    }
    if ($version !== BASE_VERSION) {
        fail(EXIT_PRECONDITION, "unexpected schema_version=$version (expected " . BASE_VERSION . ')');
    }
    out('DRY-RUN plan for ' . MIGRATION_ID . ' (applied to a disposable copy only):');
    foreach (MIGRATION_UP_SQL as $sql) {
        out('  SQL: ' . $sql);
    }
    out('  SQL: PRAGMA user_version = ' . TARGET_VERSION);

    $copy = '/tmp/lab-dryrun-' . bin2hex(random_bytes(4)) . '.sqlite';
    if (!copy(DB_PATH, $copy)) {
        fail(EXIT_PRECONDITION, 'could not create the disposable dry-run copy');
    }
    try {
        $c = open_db($copy, false);
        $c->exec('BEGIN IMMEDIATE');
        migrate_up($c);
        $c->exec('COMMIT');
        $copyVersion = schema_version($c);
        $copyTable = table_exists($c, 'lab_change_log');
        $copyDigest = data_digest($c);
        $copyIntegrity = integrity_ok($c);
        $c = null;
    } finally {
        @unlink($copy);
        @unlink($copy . '-journal');
    }
    $after = live_sha256();
    $liveVersion = schema_version(open_db(DB_PATH, true));
    if ($copyVersion !== TARGET_VERSION || !$copyTable || $copyDigest !== $digest || !$copyIntegrity) {
        fail(EXIT_PRECONDITION, 'dry-run on the disposable copy did not produce the expected result');
    }
    if ($before !== $after || $liveVersion !== BASE_VERSION) {
        fail(EXIT_PRECONDITION, 'dry-run altered the live fixture');
    }
    out(sprintf('DRY-RUN result: copy schema_version=%d lab_change_log=present data_digest=unchanged integrity=ok', $copyVersion));
    out(sprintf('PASS V-MIG-02 dry-run left live fixture untouched: live_sha256_before=%s... live_sha256_after=%s... live schema_version=%d',
        substr($before, 0, 16), substr($after, 0, 16), $liveVersion));
    [$gateOk, $gateReason] = evaluate_gate();
    out('gate (informational, enforced only by apply)=' . ($gateOk ? 'PASS' : 'REFUSED') . ' (' . $gateReason . ')');
    state_line();
    return EXIT_OK;
}

function cmd_apply(): int
{
    require_fixture();
    $pdo = open_db(DB_PATH, false);
    $version = schema_version($pdo);
    if ($version === TARGET_VERSION) {
        out('ALREADY APPLIED: migration ' . MIGRATION_ID . ' (schema_version=2); no change made.');
        $pdo = null;
        state_line();
        return EXIT_OK;
    }
    if ($version !== BASE_VERSION) {
        fail(EXIT_PRECONDITION, "unexpected schema_version=$version (expected " . BASE_VERSION . ')');
    }
    // Take the write lock first, then evaluate the gate, so nothing can change in between.
    $pdo->exec('BEGIN IMMEDIATE');
    [$ok, $reason, $archive] = evaluate_gate();
    if (!$ok) {
        $pdo->exec('ROLLBACK');
        out('GATE REFUSED: ' . $reason);
        out('REMEDIATION: ' . REMEDIATION_GATE);
        return EXIT_GATE;
    }
    out('GATE PASS: ' . $reason . ' (evaluated before any change, under the write lock)');
    $digest = data_digest($pdo);
    try {
        migrate_up($pdo);
        $journal = $pdo->prepare('INSERT INTO lab_migration_journal (migration, action, schema_before, schema_after, data_digest, backup_archive, recorded_utc)'
            . ' VALUES (:m, :a, :b, :t, :d, :arch, :now)');
        $journal->execute([':m' => MIGRATION_ID, ':a' => 'apply', ':b' => BASE_VERSION, ':t' => TARGET_VERSION,
            ':d' => $digest, ':arch' => $archive, ':now' => now_utc()]);
        $pdo->exec('COMMIT');
    } catch (Throwable $e) {
        $pdo->exec('ROLLBACK');
        fail(EXIT_PRECONDITION, 'apply failed and was rolled back (' . get_class($e) . ' code ' . $e->getCode() . ')');
    }
    $newVersion = schema_version($pdo);
    if ($newVersion !== TARGET_VERSION || !table_exists($pdo, 'lab_change_log') || data_digest($pdo) !== $digest || !integrity_ok($pdo)) {
        fail(EXIT_PRECONDITION, 'post-apply verification failed');
    }
    $pdo = null;
    out('APPLIED: ' . MIGRATION_ID . ' schema_version 1 -> 2, journal row written');
    out('PASS V-MIG-03 apply: gate passed before change; schema_version 1 -> 2; lab_change_log present; data digest unchanged; integrity=ok');
    state_line();
    return EXIT_OK;
}

function cmd_rollback(): int
{
    require_fixture();
    $pdo = open_db(DB_PATH, false);
    $version = schema_version($pdo);
    if ($version === BASE_VERSION) {
        out('NOTHING TO ROLL BACK: migration ' . MIGRATION_ID . ' is not applied (schema_version=1); no change made.');
        $pdo = null;
        state_line();
        return EXIT_OK;
    }
    if ($version !== TARGET_VERSION) {
        fail(EXIT_PRECONDITION, "unexpected schema_version=$version (expected " . TARGET_VERSION . ')');
    }
    $stmt = $pdo->prepare('SELECT data_digest FROM lab_migration_journal WHERE migration = :m AND action = :a ORDER BY id DESC LIMIT 1');
    $stmt->execute([':m' => MIGRATION_ID, ':a' => 'apply']);
    $digestAtApply = $stmt->fetchColumn();
    // Finalize the statement: SQLite refuses DROP TABLE while any statement is still active.
    $stmt->closeCursor();
    $stmt = null;
    if (!is_string($digestAtApply) || preg_match(HEX64_RE, $digestAtApply) !== 1) {
        fail(EXIT_PRECONDITION, 'no apply record for ' . MIGRATION_ID . ' in the migration journal');
    }
    try {
        $pdo->exec('BEGIN IMMEDIATE');
        foreach (MIGRATION_DOWN_SQL as $sql) {
            $pdo->exec($sql);
        }
        $journal = $pdo->prepare('INSERT INTO lab_migration_journal (migration, action, schema_before, schema_after, data_digest, backup_archive, recorded_utc)'
            . ' VALUES (:m, :a, :b, :t, :d, NULL, :now)');
        $journal->execute([':m' => MIGRATION_ID, ':a' => 'rollback', ':b' => TARGET_VERSION, ':t' => BASE_VERSION,
            ':d' => data_digest($pdo), ':now' => now_utc()]);
        $pdo->exec('PRAGMA user_version = ' . BASE_VERSION);
        $pdo->exec('COMMIT');
    } catch (Throwable $e) {
        $pdo->exec('ROLLBACK');
        fail(EXIT_PRECONDITION, 'rollback failed and was reverted (' . get_class($e) . ' code ' . $e->getCode() . ')');
    }
    $ok = schema_version($pdo) === BASE_VERSION
        && !table_exists($pdo, 'lab_change_log')
        && fixture_marker($pdo) === MARKER
        && data_digest($pdo) === $digestAtApply
        && integrity_ok($pdo);
    $pdo = null;
    if (!$ok) {
        fail(EXIT_PRECONDITION, 'post-rollback verification failed (version, table, marker, digest or integrity)');
    }
    out('ROLLED BACK: ' . MIGRATION_ID . ' schema_version 2 -> 1, journal row written');
    out('PASS V-RB-01 rollback: schema_version 2 -> 1; lab_change_log absent; marker intact; data digest equals digest at apply; integrity=ok');
    state_line();
    return EXIT_OK;
}

$command = $argv[1] ?? '';
$commands = [
    'init' => 'cmd_init',
    'status' => 'cmd_status',
    'dry-run' => 'cmd_dry_run',
    'apply' => 'cmd_apply',
    'rollback' => 'cmd_rollback',
    'gate-check' => 'cmd_gate_check',
];
if (!isset($commands[$command]) || $argc !== 2) {
    out('usage: migrate.php init|status|dry-run|apply|rollback|gate-check');
    exit(EXIT_USAGE);
}
try {
    exit($commands[$command]());
} catch (Throwable $e) {
    fail(EXIT_PRECONDITION, 'unexpected failure (' . get_class($e) . ' code ' . $e->getCode() . ')');
}
