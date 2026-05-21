FROM docker.io/moodlehq/moodle-php-apache:8.3@sha256:091e1fc7e4b7f41f210e6b090f7d7bbe686d2a1ad3012504d0d4e738f56c3aa5

ARG MOODLE_BRANCH=MOODLE_500_STABLE
# Optional: pin to an exact commit SHA for fully reproducible builds.
# Usage: --build-arg MOODLE_COMMIT=<full-sha>
# When set, the clone is done with --no-single-branch so the commit is fetchable,
# then checked out to exactly that SHA, ensuring the image is byte-for-byte reproducible.
ARG MOODLE_COMMIT=""

# Install Moodle source (moodlehq base already has all PHP extensions + sodium)
RUN apt-get update && \
    apt-get install -y --no-install-recommends git && \
    git clone --depth=1 --branch "${MOODLE_BRANCH}" \
        https://github.com/moodle/moodle.git /tmp/moodle && \
    if [ -n "${MOODLE_COMMIT}" ]; then \
        git -C /tmp/moodle fetch --depth=1 origin "${MOODLE_COMMIT}" && \
        git -C /tmp/moodle checkout FETCH_HEAD; \
    fi && \
    rm -rf /tmp/moodle/.git && \
    rm -rf /var/www/html && \
    mv /tmp/moodle /var/www/html && \
    mkdir -p /var/www/moodledata && \
    apt-get purge -y --auto-remove git && \
    rm -rf /var/lib/apt/lists/*

# Non-privileged port for cap_drop: ALL
# Raise header limit — OAuth2 proxy cookies on wildcard domain can exceed 8190 default
RUN sed -i 's/Listen 80$/Listen 8080/' /etc/apache2/ports.conf && \
    sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-available/000-default.conf

# Moodle config and first-boot installer
COPY config/config.php /var/www/html/config.php
COPY config/apache-limits.conf /etc/apache2/conf-enabled/limits.conf
COPY config/entrypoint.d/20-moodle-install.sh /docker-entrypoint.d/20-moodle-install.sh
COPY docker-entrypoint.d/30-setup-sso.sh /docker-entrypoint.d/30-setup-sso.sh

RUN chown -R www-data:www-data \
        /var/www/html \
        /var/www/moodledata \
        /var/run/apache2 \
        /var/lock/apache2 \
        /var/log/apache2 \
        /usr/local/etc/php/conf.d && \
    mkdir -p /system-docker-entrypoint.d /final-docker-entrypoint.d && \
    chown -R www-data:www-data \
        /system-docker-entrypoint.d \
        /final-docker-entrypoint.d \
        /docker-entrypoint.d && \
    chmod +x /docker-entrypoint.d/20-moodle-install.sh \
               /docker-entrypoint.d/30-setup-sso.sh

EXPOSE 8080
USER www-data
