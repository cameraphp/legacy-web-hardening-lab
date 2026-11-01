# LAB ONLY: one-shot backup creator and isolated-restore verifier (REQ-BACKUP-001..002).
# Pinned tag. A real deployment should independently review and pin the image digest.
FROM alpine:3.24.3

RUN apk add --no-cache bash sqlite

COPY backup-verify.sh /usr/local/bin/backup-verify
RUN sed -i 's/\r$//' /usr/local/bin/backup-verify && chmod 0755 /usr/local/bin/backup-verify

ENTRYPOINT ["/usr/local/bin/backup-verify"]
