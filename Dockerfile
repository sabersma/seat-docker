FROM php:8.4-alpine AS seat-core

# Optional GitHub token for private repositories (composer reads COMPOSER_AUTH env)
ARG COMPOSER_AUTH
ENV COMPOSER_AUTH=${COMPOSER_AUTH}

# Composer and Git (git needed for VCS repositories)
RUN apk add --no-cache git && \
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin \
    --filename=composer && hash -r

# Clone SeAT from fork, configure VCS repo for custom notifications package, then install
COPY version /tmp/seat-version
RUN git config --global url."https://github.com/".insteadOf git@github.com: && \
    git config --global url."https://".insteadOf git:// && \
    git clone --depth 1 --branch feature/sfi https://github.com/sabersma/seat.git /seat && \
    cd /seat && \
    mv /tmp/seat-version /seat/storage/version && \
    php -r "file_exists('.env') || copy('.env.example', '.env');" && \
    rm -f composer.lock && \
    composer config repositories.notifications vcs https://github.com/sabersma/eveseat-notifications && \
    composer install --no-scripts --no-dev --no-ansi --no-progress --ignore-platform-reqs && \
    composer clear-cache --no-ansi

FROM php:8.4-apache-bookworm AS seat

# Optional GitHub token for composer VCS operations at runtime (e.g. plugin install)
ARG COMPOSER_AUTH
ENV COMPOSER_AUTH=${COMPOSER_AUTH}

# OS Packages
# - networking diagnose tools
# - build tools
# - compression libraries and tools
# - databases libraries
# - picture and drawing libraries
# - others
RUN export DEBIAN_FRONTEND=noninteractive \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
    iputils-ping dnsutils \ 
    pkg-config build-essential \
    zip unzip libzip-dev libbz2-dev \
    mariadb-client libpq-dev redis-tools libpq5 postgresql-client \
    libpng-dev libjpeg62-turbo-dev libfreetype6-dev libwebp-dev \
    jq libgmp-dev libicu-dev nano git \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# PHP Extentions
RUN pecl install redis && \
    docker-php-ext-configure gd \
        --with-freetype \
        --with-webp \
        --with-jpeg && \
    docker-php-ext-configure pgsql && \
    docker-php-ext-install -j$(nproc) zip pdo pdo_mysql pdo_pgsql gd bz2 gmp intl pcntl opcache && \
    docker-php-ext-enable redis && \
    apt-get autoremove

# Composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin \
    --filename=composer && hash -r

# User and Group
RUN groupadd -r -g 200 seat && useradd --no-log-init -r -g seat -u 200 seat && \
    mkdir -p /home/seat/.cache/composer/vcs && \
    chown -R seat:seat /home/seat

# Force git to use HTTPS instead of SSH (prevent "git@github.com" failures in composer)
# Use --system so it applies to the seat user at runtime
RUN git config --system url."https://github.com/".insteadOf git@github.com:

# Changing default Apache port to allow rootless container exploitation
#
# If the Listen specified in the configuration file is default of 80 (or any other port below 1024),
# then it is necessary to have root privileges in order to start apache, so that it can bind to this privileged port.
# Once the server has started and performed a few preliminary activities such as opening its log files, it will launch
# several child processes which do the work of listening for and answering requests from clients. The main httpd process
# continues to run as the root user, but the child processes run as a less privileged user.

RUN sed -i 's/80/8080/g' /etc/apache2/sites-available/000-default.conf /etc/apache2/ports.conf
RUN a2enmod rewrite

COPY --from=seat-core /seat /var/www/seat
RUN chown -R seat:seat /var/www/seat

# Expose only the public directory to Apache
RUN rmdir /var/www/html && \
    ln -s /var/www/seat/public /var/www/html

WORKDIR /var/www/seat

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

USER seat
EXPOSE 8080
ENTRYPOINT ["/docker-entrypoint.sh"]
