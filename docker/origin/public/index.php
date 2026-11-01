<?php
// LAB ONLY: landing page (REQ-SAFE-002, REQ-ORIGIN-004). No script, style or images (CSP default-src 'none').
declare(strict_types=1);
require __DIR__ . '/../lib/lab.php';

$summary = lab_fixture_summary();
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>legacy-web-hardening-lab</title>
</head>
<body>
<h1>legacy-web-hardening-lab</h1>
<p><strong><?= htmlspecialchars(LAB_WARNING, ENT_QUOTES | ENT_HTML5, 'UTF-8') ?></strong></p>
<p>A legacy-style PHP origin served through a local Nginx TLS edge. Cloudflare-style edge/origin
separation and header sanitation only; no Cloudflare product is involved.</p>
<p>Synthetic fixture: <?= $summary['ok'] ? 'available' : 'unavailable' ?>,
items: <?= (int) $summary['items'] ?>, schema version: <?= (int) $summary['schema'] ?>.</p>
<ul>
<li><a href="/health">/health</a>: minimal health status</li>
<li><a href="/session">/session</a>: lab-only session counter</li>
<li><a href="/lab/request-context">/lab/request-context</a>: sanitized request context</li>
</ul>
</body>
</html>
