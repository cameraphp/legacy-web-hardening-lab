<?php
// LAB ONLY: container healthcheck for the origin.
// Healthy means Apache answers on port 80 AND correctly refuses a non-edge peer (127.0.0.1) with 403.
// That proves the service is up without adding a loopback exception to the edge-only access rule.
declare(strict_types=1);

$socket = @fsockopen('127.0.0.1', 80, $errno, $errstr, 2.0);
if ($socket === false) {
    exit(1);
}
stream_set_timeout($socket, 2);
fwrite($socket, "GET /health HTTP/1.0\r\nHost: localhost\r\n\r\n");
$status = (string) fgets($socket, 128);
fclose($socket);

exit(preg_match('#^HTTP/1\.[01] 403 #', $status) === 1 ? 0 : 1);
