<?php
// LAB ONLY: sanitized request context for acceptance tests (REQ-FWD-003, REQ-FWD-004).
// Returns a fixed set of fields only. Never returns environment variables, filesystem paths, secrets,
// full headers, cookies or configuration.
declare(strict_types=1);
require __DIR__ . '/../lib/lab.php';

$viaEdge = ($_SERVER['LAB_VIA_EDGE'] ?? '') === '1';

// Forwarding headers the edge must never pass through. We report only their names, never values.
$deny = [
    'HTTP_FORWARDED' => 'Forwarded',
    'HTTP_CF_CONNECTING_IP' => 'CF-Connecting-IP',
    'HTTP_CF_CONNECTING_IPV6' => 'CF-Connecting-IPv6',
    'HTTP_CF_IPCOUNTRY' => 'CF-IPCountry',
    'HTTP_CF_RAY' => 'CF-Ray',
    'HTTP_CF_VISITOR' => 'CF-Visitor',
    'HTTP_TRUE_CLIENT_IP' => 'True-Client-IP',
    'HTTP_X_CLIENT_IP' => 'X-Client-IP',
    'HTTP_X_CLUSTER_CLIENT_IP' => 'X-Cluster-Client-IP',
    'HTTP_X_ORIGINAL_FORWARDED_FOR' => 'X-Original-Forwarded-For',
    'HTTP_FORWARDED_FOR' => 'Forwarded-For',
    'HTTP_X_FORWARDED' => 'X-Forwarded',
    'HTTP_X_ORIGINAL_URL' => 'X-Original-URL',
    'HTTP_X_REWRITE_URL' => 'X-Rewrite-URL',
];
$allowedForwarded = ['HTTP_X_FORWARDED_FOR', 'HTTP_X_FORWARDED_PROTO', 'HTTP_X_FORWARDED_PORT', 'HTTP_X_FORWARDED_HOST'];

$unexpected = [];
foreach ($_SERVER as $key => $_value) {
    if (!is_string($key)) {
        continue;
    }
    if (isset($deny[$key])) {
        $unexpected[] = $deny[$key];
    } elseif (str_starts_with($key, 'HTTP_X_FORWARDED_') && !in_array($key, $allowedForwarded, true)) {
        $unexpected[] = 'X-Forwarded-' . ucwords(strtolower(str_replace('_', '-', substr($key, 17))), '-');
    }
}
sort($unexpected);

$host = (string) ($_SERVER['HTTP_HOST'] ?? '');
if (!preg_match('/^[a-z0-9.\-]{1,64}$/', $host)) {
    $host = 'invalid';
}
// mod_remoteip removes the X-Forwarded-For entries it consumed from the trusted edge. Anything left over
// would be an unconsumed, client-controlled chain (for example, if a proxy appended instead of overwriting).
$xff = trim((string) ($_SERVER['HTTP_X_FORWARDED_FOR'] ?? ''));
$unconsumed = $xff === '' ? 0 : count(explode(',', $xff));
$port = $viaEdge ? (int) ($_SERVER['HTTP_X_FORWARDED_PORT'] ?? 0) : null;

lab_json(200, [
    'client_ip' => (string) ($_SERVER['REMOTE_ADDR'] ?? ''),
    'scheme' => (($_SERVER['HTTPS'] ?? '') === 'on') ? 'https' : 'http',
    'host' => $host,
    'forwarded_port' => $port,
    'via_trusted_edge' => $viaEdge,
    'x_forwarded_for_unconsumed' => $unconsumed,
    'unexpected_forwarding_headers' => $unexpected,
]);
