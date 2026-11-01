<?php
// LAB ONLY: shared helpers for the fictional legacy-style origin. Synthetic fixture data only.
declare(strict_types=1);

const LAB_DB_PATH = '/var/lib/lab/state/lab.sqlite';
const LAB_FIXTURE_MARKER = 'LAB_BACKUP_FIXTURE=v1';
const LAB_WARNING = 'LAB ONLY — fictional local hardening demonstration; do not use with client data or production systems.';

/** Opens the synthetic fixture read-only. The origin mounts the state volume read-only as well. */
function lab_open_readonly(): ?Pdo\Sqlite
{
    if (!is_file(LAB_DB_PATH)) {
        return null;
    }
    try {
        return new Pdo\Sqlite('sqlite:' . LAB_DB_PATH, null, null, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            Pdo\Sqlite::ATTR_OPEN_FLAGS => Pdo\Sqlite::OPEN_READONLY,
        ]);
    } catch (Throwable) {
        return null;
    }
}

/** @return array{ok: bool, items: int, schema: int} */
function lab_fixture_summary(): array
{
    $pdo = lab_open_readonly();
    if ($pdo === null) {
        return ['ok' => false, 'items' => 0, 'schema' => 0];
    }
    try {
        $marker = $pdo->query("SELECT value FROM lab_meta WHERE key = 'fixture_marker'")->fetchColumn();
        $items = (int) $pdo->query('SELECT COUNT(*) FROM lab_items')->fetchColumn();
        $schema = (int) $pdo->query('PRAGMA user_version')->fetchColumn();
        return ['ok' => $marker === LAB_FIXTURE_MARKER && $items > 0, 'items' => $items, 'schema' => $schema];
    } catch (Throwable) {
        return ['ok' => false, 'items' => 0, 'schema' => 0];
    }
}

/** Sends a small JSON response and stops. Never includes environment, paths or headers. */
function lab_json(int $status, array $body): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($body, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR), "\n";
    exit;
}
