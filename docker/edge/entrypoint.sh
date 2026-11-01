#!/bin/sh
# LAB ONLY: generates an ephemeral self-signed certificate on tmpfs at every container start.
# The key never leaves the container's tmpfs, is never logged, and is never written to the project.
set -eu

TLS_DIR=/run/lab-tls
umask 077
mkdir -p "$TLS_DIR"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -days 7 \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=serverAuth" \
  -keyout "$TLS_DIR/lab.key" \
  -out "$TLS_DIR/lab.crt" >/dev/null 2>&1

chmod 0600 "$TLS_DIR/lab.key"
chmod 0644 "$TLS_DIR/lab.crt"
echo "lab-edge: generated ephemeral self-signed certificate (CN=localhost, 7 days) on tmpfs"

nginx -t -q
exec "$@"
