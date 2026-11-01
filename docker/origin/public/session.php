<?php
// LAB ONLY: lab session counter (REQ-SESSION-001..004). Cookie settings come from php-hardening.ini:
// LABSESSID, Secure, HttpOnly, SameSite=Lax, no Domain, cookie-only, strict mode.
declare(strict_types=1);
require __DIR__ . '/../lib/lab.php';

session_start();
$counter = (int) ($_SESSION['lab_counter'] ?? 0) + 1;
$_SESSION['lab_counter'] = $counter;
session_write_close();

lab_json(200, ['lab_session_counter' => $counter]);
