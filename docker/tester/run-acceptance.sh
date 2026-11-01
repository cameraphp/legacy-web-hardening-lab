#!/usr/bin/env bash
# LAB ONLY: containerized acceptance checks for legacy-web-hardening-lab.
# Modes:
#   all            run every tester check (V-TLS, V-EDGE, V-FWD, V-ORIGIN, V-SESS)
#   wait           poll /health through the edge until ready (used by lab.ps1 up)
#   health <ID>    single /health check through the edge, reported under <ID>
# Output never includes session IDs, cookie values, private keys or full header dumps.
# TLS verification is bypassed (-k) ONLY where a check says so: this lab uses a self-signed certificate.
set -uo pipefail

EDGE_ALIAS=lab-edge                      # edge's alias on edge_net (not the internal origin_net IP)
ORIGIN_IP=172.28.0.10
BASE=https://localhost
CONNECT=(--connect-to "localhost:443:${EDGE_ALIAS}:443")
WARNING='LAB ONLY — fictional local hardening demonstration; do not use with client data or production systems.'
WORK=$(mktemp -d /tmp/acceptance.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "PASS $1 $2"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL $1 $2"; }
result() { if [ "$1" = "0" ]; then pass "$2" "$3"; else fail "$2" "$3"; fi; }

# req <name> [curl args...] -> prints "<http_code> <local_ip>"; headers in $WORK/<name>.h, body in .b
req() {
  local name=$1; shift
  curl -sS -k --max-time 10 "${CONNECT[@]}" -D "$WORK/$name.h" -o "$WORK/$name.b" \
    -w '%{http_code} %{local_ip}' "$@" 2>/dev/null || echo "000 -"
}
# hval <name> <header>: values of a header (case-insensitive), one per line, CR stripped
hval() { grep -i "^$2:" "$WORK/$1.h" | tr -d '\r' | cut -d: -f2- | sed 's/^ *//'; }
hcount() { grep -ci "^$2:" "$WORK/$1.h" || true; }
token() { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }

health_once() {
  local out code
  out=$(req health "$BASE/health")
  code=${out%% *}
  [ "$code" = "200" ] && [ "$(tr -d '\r\n' < "$WORK/health.b")" = '{"status":"ok"}' ]
}

mode_wait() {
  for _ in $(seq 1 60); do
    if health_once; then echo "READY edge -> origin /health is ok"; return 0; fi
    sleep 1
  done
  echo "ERROR: edge did not report healthy within 60 s"
  echo "REMEDIATION: run 'docker compose -p legacy-web-hardening-lab logs edge origin' and retry .\\scripts\\lab.ps1 up"
  return 1
}

mode_health() {
  local id=$1
  for _ in $(seq 1 15); do
    if health_once; then pass "$id" "/health through the edge returned 200 {\"status\":\"ok\"}"; return 0; fi
    sleep 1
  done
  fail "$id" "/health through the edge did not return 200 {\"status\":\"ok\"}"
  return 1
}

check_tls() {
  local rc out cert subj iss san
  # V-TLS-01: default verification must reject the self-signed certificate.
  curl -sS --max-time 10 "${CONNECT[@]}" -o /dev/null "$BASE/" 2>/dev/null; rc=$?
  [ "$rc" = "60" ]; result $? V-TLS-01 "strict TLS verification rejects the self-signed certificate (curl exit $rc, expected 60)"

  # V-TLS-02: explicit, lab-only verification bypass.
  out=$(req tls02 "$BASE/")
  [ "${out%% *}" = "200" ]; result $? V-TLS-02 "explicit -k (lab only) returns HTTP ${out%% *}"

  out=$(openssl s_client -brief -connect "${EDGE_ALIAS}:443" -servername localhost -tls1_2 </dev/null 2>&1)
  grep -q 'Protocol version: TLSv1.2' <<<"$out"; result $? V-TLS-03 "TLS 1.2 handshake succeeds"

  out=$(openssl s_client -brief -connect "${EDGE_ALIAS}:443" -servername localhost -tls1_3 </dev/null 2>&1)
  grep -q 'Protocol version: TLSv1.3' <<<"$out"; result $? V-TLS-04 "TLS 1.3 handshake succeeds"

  out=$(openssl s_client -brief -connect "${EDGE_ALIAS}:443" -servername localhost -tls1_1 -cipher 'DEFAULT:@SECLEVEL=0' </dev/null 2>&1); rc=$?
  if [ "$rc" != "0" ] && ! grep -q 'CONNECTION ESTABLISHED' <<<"$out"; then
    if grep -qiE 'no protocols available' <<<"$out"; then
      fail V-TLS-05 "TLS 1.1 could not be offered by the test client, so server refusal is unproven"
    else
      pass V-TLS-05 "TLS 1.1 handshake refused by the edge ($(grep -oiE 'alert [a-z ]+|unsupported protocol|wrong version number' <<<"$out" | head -n1))"
    fi
  else
    fail V-TLS-05 "TLS 1.1 handshake was accepted"
  fi

  cert=$(openssl s_client -connect "${EDGE_ALIAS}:443" -servername localhost </dev/null 2>/dev/null | openssl x509 2>/dev/null)
  subj=$(openssl x509 -noout -subject -nameopt RFC2253 <<<"$cert" 2>/dev/null | sed 's/^subject=//')
  iss=$(openssl x509 -noout -issuer -nameopt RFC2253 <<<"$cert" 2>/dev/null | sed 's/^issuer=//')
  san=$(openssl x509 -noout -ext subjectAltName <<<"$cert" 2>/dev/null | tail -n +2 | tr -d ' ')
  if [ -n "$cert" ] && [ "$subj" = "CN=localhost" ] && [ "$subj" = "$iss" ] \
     && grep -q 'DNS:localhost' <<<"$san" && grep -q 'IPAddress:127.0.0.1' <<<"$san" \
     && openssl x509 -noout -checkend 0 <<<"$cert" >/dev/null 2>&1 \
     && ! openssl x509 -noout -checkend 691200 <<<"$cert" >/dev/null 2>&1; then
    pass V-TLS-06 "certificate is self-signed (subject=issuer=$subj), SAN=$san, valid now and expires within 8 days"
  else
    fail V-TLS-06 "certificate properties unexpected (subject=$subj issuer=$iss san=$san)"
  fi
}

check_edge() {
  local out code ok bad good m
  out=$(req home "$BASE/"); code=${out%% *}
  [ "$code" = "200" ] && hval home content-type | grep -qi 'text/html; *charset=utf-8' && grep -qF "$WARNING" "$WORK/home.b"
  result $? V-EDGE-01 "GET / returns 200 text/html utf-8 with the exact lab-only warning"

  ok=0
  [ "$(hcount home x-content-type-options)" = "1" ] && [ "$(hval home x-content-type-options)" = "nosniff" ] || ok=1
  [ "$(hcount home x-frame-options)" = "1" ] && [ "$(hval home x-frame-options)" = "DENY" ] || ok=1
  [ "$(hcount home referrer-policy)" = "1" ] && [ "$(hval home referrer-policy)" = "no-referrer" ] || ok=1
  [ "$(hcount home content-security-policy)" = "1" ] && hval home content-security-policy | grep -q "default-src 'none'" \
    && hval home content-security-policy | grep -q "frame-ancestors 'none'" || ok=1
  result $ok V-EDGE-02 "security headers present exactly once: nosniff, DENY, no-referrer, CSP default-src 'none'"

  [ "$(hcount home strict-transport-security)" = "0" ]
  result $? V-EDGE-03 "Strict-Transport-Security deliberately absent (self-signed localhost lab)"

  out=$(req sess0 "$BASE/session")
  ok=0
  [ "$(hval home server)" = "nginx" ] || ok=1
  [ "$(hcount home x-powered-by)" = "0" ] && [ "$(hcount sess0 x-powered-by)" = "0" ] || ok=1
  grep -qiE 'apache|php/|nginx/' "$WORK/home.h" "$WORK/sess0.h" && ok=1
  result $ok V-EDGE-04 "Server is exactly 'nginx'; no X-Powered-By; no Apache/PHP/nginx version strings in headers"

  bad=$(token); good=$(token)
  out=$(req badhost -H 'Host: unexpected.invalid' "$BASE/lab/request-context?probe=$bad"); code=${out%% *}
  [ "$code" = "421" ] && [ "$(hcount badhost set-cookie)" = "0" ] && grep -q 'Misdirected Request' "$WORK/badhost.b" \
    && ! grep -q 'client_ip' "$WORK/badhost.b"
  result $? V-EDGE-05 "unexpected Host rejected with $code by the edge (no origin JSON, no Set-Cookie)"
  req goodhost "$BASE/lab/request-context?probe=$good" >/dev/null
  echo "PROBE bad=$bad good=$good"

  out=$(req trace -X TRACE "$BASE/"); code=${out%% *}
  [ "$code" = "405" ]; result $? V-EDGE-06 "TRACE returns $code (expected 405)"

  ok=0; codes=""
  for m in POST PUT DELETE OPTIONS; do
    out=$(req "m_$m" -X "$m" "$BASE/"); codes="$codes $m=${out%% *}"
    [ "${out%% *}" = "405" ] || ok=1
  done
  result $ok V-EDGE-07 "other methods rejected:$codes"

  out=$(req dir "$BASE/static/"); code=${out%% *}
  [ "$code" = "404" ] && [ "$(tr -d '\r\n' < "$WORK/dir.b")" = "Not Found" ] && ! grep -qi 'Index of' "$WORK/dir.b"
  result $? V-EDGE-08 "directory without index returns $code with the generic body and no listing (mod_autoindex disabled)"

  out=$(req nf "$BASE/does-not-exist"); code=${out%% *}
  [ "$code" = "404" ] && ! grep -qiE 'apache|/var/|php|warning|stack' "$WORK/nf.b"
  result $? V-EDGE-09 "unknown path returns $code with a generic body (no version, path or stack)"
}

ctx_ok() { # ctx_ok <name> <expected_client_ip>
  jq -e --arg ip "$2" '.scheme == "https" and .forwarded_port == 443 and .host == "localhost"
      and .via_trusted_edge == true and .client_ip == $ip and .x_forwarded_for_unconsumed == 0' "$WORK/$1.b" >/dev/null 2>&1
}

check_forwarding() {
  local out code lip ok
  out=$(req ctx "$BASE/lab/request-context"); code=${out%% *}; lip=${out#* }
  [ "$code" = "200" ] && ctx_ok ctx "$lip"
  result $? V-FWD-01 "edge-rebuilt context: scheme=https port=443 host=localhost via_trusted_edge=true client_ip=observed peer ($lip)"

  out=$(req forged \
    -H 'X-Forwarded-For: 203.0.113.66, 198.51.100.7' \
    -H 'X-Real-IP: 203.0.113.67' \
    -H 'Forwarded: for=203.0.113.68;proto=http;host=forged.invalid' \
    -H 'CF-Connecting-IP: 203.0.113.69' \
    -H 'True-Client-IP: 203.0.113.70' \
    -H 'X-Client-IP: 203.0.113.71' \
    -H 'X-Forwarded-Proto: http' \
    -H 'X-Forwarded-Host: forged.invalid' \
    -H 'X-Forwarded-Port: 80' \
    -H 'X-Forwarded-Prefix: /forged' \
    "$BASE/lab/request-context"); code=${out%% *}; lip=${out#* }
  ok=1
  if [ "$code" = "200" ] && ctx_ok forged "$lip" \
     && jq -e '.unexpected_forwarding_headers == []' "$WORK/forged.b" >/dev/null 2>&1 \
     && ! grep -qE '203\.0\.113\.|198\.51\.100\.|forged\.invalid|/forged' "$WORK/forged.b"; then ok=0; fi
  result $ok V-FWD-02 "forged XFF/X-Real-IP/Forwarded/CF-Connecting-IP/True-Client-IP/X-Forwarded-* did not control PHP context"

  ok=1
  if jq -e '(keys | sort) == (["client_ip","forwarded_port","host","scheme","unexpected_forwarding_headers","via_trusted_edge","x_forwarded_for_unconsumed"])' "$WORK/ctx.b" >/dev/null 2>&1 \
     && ! grep -qiE 'DOCUMENT_ROOT|/var/www|PATH=|HTTP_COOKIE|LABSESSID|SERVER_SOFTWARE' "$WORK/ctx.b"; then ok=0; fi
  result $ok V-FWD-03 "request-context returns only the 7 documented sanitized fields (no env, paths, cookies or headers)"
}

check_origin() {
  local code
  code=$(curl -sS --max-time 5 -o "$WORK/direct.b" -w '%{http_code}' -H 'Host: localhost' "http://${ORIGIN_IP}/health" 2>/dev/null || echo 000)
  [ "$code" = "403" ]; result $? V-ORIGIN-01 "direct HTTP to origin from tester (172.28.0.20, bypassing Nginx) denied with $code"

  code=$(curl -sS --max-time 5 -o "$WORK/direct2.b" -w '%{http_code}' -H 'Host: localhost' \
    -H 'X-Forwarded-For: 172.28.0.2' -H 'X-Forwarded-Proto: https' "http://${ORIGIN_IP}/" 2>/dev/null || echo 000)
  [ "$code" = "403" ]; result $? V-ORIGIN-02 "direct request with forged X-Forwarded-For: 172.28.0.2 still denied with $code"

  health_once; result $? V-ORIGIN-03 "/health through the edge still returns 200 {\"status\":\"ok\"} after direct attempts"
}

check_session() {
  local jar=$WORK/jar out c1 c2 attrs ok forged newid
  rm -f "$jar"
  out=$(req s1 -c "$jar" "$BASE/session")
  attrs=$(hval s1 set-cookie | sed -E 's/^[^=]+=[^;]*//')
  ok=1
  if [ "$(hcount s1 set-cookie)" = "1" ] && hval s1 set-cookie | grep -q '^LABSESSID=' \
     && grep -qi '; *secure' <<<"$attrs" && grep -qi '; *httponly' <<<"$attrs" \
     && grep -qi '; *samesite=lax' <<<"$attrs" && grep -qi '; *path=/' <<<"$attrs" \
     && ! grep -qi 'domain=' <<<"$attrs" && ! grep -qi 'PHPSESSID' "$WORK/s1.h"; then ok=0; fi
  result $ok V-SESS-01 "single host-only LABSESSID cookie, attributes:${attrs} (value not printed; no Domain, no PHPSESSID)"

  c1=$(jq -r '.lab_session_counter' "$WORK/s1.b" 2>/dev/null)
  req s2 -b "$jar" -c "$jar" "$BASE/session" >/dev/null
  c2=$(jq -r '.lab_session_counter' "$WORK/s2.b" 2>/dev/null)
  [ "$c1" = "1" ] && [ "$c2" = "2" ]; result $? V-SESS-02 "cookie jar preserves the lab session counter ($c1 -> $c2)"

  forged="labfixation$(token)$(token)"
  req s3 -H "Cookie: LABSESSID=$forged" "$BASE/session" >/dev/null
  newid=$(hval s3 set-cookie | sed -nE 's/^LABSESSID=([^;]*).*/\1/p')
  [ -n "$newid" ] && [ "$newid" != "$forged" ] && [ "$(jq -r '.lab_session_counter' "$WORK/s3.b" 2>/dev/null)" = "1" ]
  result $? V-SESS-03 "client-chosen session ID rejected by strict mode (new ID issued: yes; counter reset to 1)"

  hval s1 cache-control | grep -qi 'no-store'
  result $? V-SESS-04 "session response is non-cacheable (Cache-Control contains no-store)"
}

case "${1:-all}" in
  wait) mode_wait; exit $? ;;
  health) mode_health "${2:?health requires a validation ID}"; exit $? ;;
  all)
    check_tls
    check_edge
    check_forwarding
    check_origin
    check_session
    echo "SUMMARY tester passed=$PASSED failed=$FAILED"
    [ "$FAILED" = "0" ] ;;
  *) echo "usage: run-acceptance all|wait|health <ID>"; exit 2 ;;
esac
