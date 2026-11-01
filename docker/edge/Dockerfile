# LAB ONLY: Nginx TLS edge for legacy-web-hardening-lab (REQ-EDGE-001..007).
# Pinned tag. A real deployment should independently review and pin the image digest.
FROM nginx:1.30.6-alpine3.24

# openssl is needed only to generate the ephemeral self-signed lab certificate at startup.
RUN apk add --no-cache openssl \
 && rm -f /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /usr/local/bin/lab-edge-entrypoint

RUN sed -i 's/\r$//' /etc/nginx/nginx.conf /usr/local/bin/lab-edge-entrypoint \
 && chmod 0644 /etc/nginx/nginx.conf \
 && chmod 0755 /usr/local/bin/lab-edge-entrypoint

EXPOSE 443
STOPSIGNAL SIGQUIT
ENTRYPOINT ["/usr/local/bin/lab-edge-entrypoint"]
CMD ["nginx", "-g", "daemon off;"]
