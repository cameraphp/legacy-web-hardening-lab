<?php
// LAB ONLY: minimal, non-sensitive health status (REQ-ORIGIN-004).
declare(strict_types=1);
require __DIR__ . '/../lib/lab.php';

if (lab_fixture_summary()['ok']) {
    lab_json(200, ['status' => 'ok']);
}
lab_json(503, ['status' => 'unavailable']);
