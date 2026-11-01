# LAB ONLY: legacy-style PHP/Apache origin for legacy-web-hardening-lab (REQ-ORIGIN-001..004).
# "Legacy" is the application pattern (mod_php, file-per-endpoint, HTTP-only origin, file sessions),
# not the runtime: PHP 8.5 is a supported line. A real deployment should pin the reviewed image digest.
FROM php:8.5.12-apache-trixie

RUN set -eux; \
    cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"; \
    a2enmod remoteip headers; \
    a2dismod -f autoindex status access_compat negotiation; \
    a2disconf charset localized-error-pages other-vhosts-access-log security serve-cgi-bin; \
    rm -f /etc/apache2/sites-enabled/*; \
    printf 'Listen 80\n' > /etc/apache2/ports.conf; \
    mkdir -p /var/www/lab/public /var/www/lab/lib /var/lib/lab/state /var/lib/lab/sessions /opt/lab/bin; \
    chmod 0755 /var/lib/lab/state; \
    chown www-data:www-data /var/lib/lab/sessions; \
    chmod 0700 /var/lib/lab/sessions

COPY apache-hardening.conf /etc/apache2/conf-available/lab-hardening.conf
COPY apache-vhost.conf /etc/apache2/sites-available/lab-origin.conf
COPY php-hardening.ini /usr/local/etc/php/conf.d/zz-lab-hardening.ini
COPY public/ /var/www/lab/public/
COPY lib/ /var/www/lab/lib/
COPY bin/ /opt/lab/bin/

RUN set -eux; \
    find /etc/apache2/conf-available/lab-hardening.conf /etc/apache2/sites-available/lab-origin.conf \
         /usr/local/etc/php/conf.d/zz-lab-hardening.ini /var/www/lab /opt/lab -type f \
         -exec sed -i 's/\r$//' {} +; \
    chown -R root:root /var/www/lab /opt/lab; \
    find /var/www/lab /opt/lab -type d -exec chmod 0755 {} +; \
    find /var/www/lab /opt/lab -type f -exec chmod 0644 {} +; \
    a2enconf lab-hardening; \
    a2ensite lab-origin; \
    apache2ctl -t

EXPOSE 80
