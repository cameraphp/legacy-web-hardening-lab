# LAB ONLY: containerized acceptance runner (REQ-TEST-001). No host curl, OpenSSL or Bash needed.
# Pinned tag. A real deployment should independently review and pin the image digest.
FROM alpine:3.24.3

RUN apk add --no-cache bash curl openssl jq ca-certificates

COPY run-acceptance.sh /usr/local/bin/run-acceptance
RUN sed -i 's/\r$//' /usr/local/bin/run-acceptance && chmod 0755 /usr/local/bin/run-acceptance

USER 65534:65534
ENTRYPOINT ["/usr/local/bin/run-acceptance"]
CMD ["all"]
