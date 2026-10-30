# Version PHP figée ici, seul endroit : elle suit le code (relue en PR, testée, revert possible).
# Jamais dans .docker/.env, que le déploiement ne synchronise pas (docs/DECISIONS.md, 2026-10-21).
FROM php:8.4-fpm

ARG UID=1000
ARG GID=1000

# Extensions communes à Symfony, WordPress et PrestaShop 9 (gd, intl, zip, pdo_mysql, mysqli,
# exif, bcmath, opcache, soap) ; pcntl : arrêt propre du worker Messenger sur SIGTERM.
# msmtp : sendmail minimal ; en local, php/91-local-mail.ini y envoie mail() vers Mailpit.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git unzip curl msmtp \
        libzip-dev libpng-dev libfreetype6-dev libjpeg62-turbo-dev libwebp-dev libicu-dev libxml2-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql mysqli zip gd intl exif bcmath opcache pcntl soap \
    && rm -rf /var/lib/apt/lists/*

ARG COMPOSER_VERSION=2
RUN curl -sS https://getcomposer.org/installer \
    | php -- --install-dir=/usr/local/bin --filename=composer --${COMPOSER_VERSION}

# wp-cli dans l'image : WordPress (make core, db-pull, search-replace) en dépend ; inerte ailleurs.
RUN curl -sSLo /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /usr/local/bin/wp

ARG ENABLE_XDEBUG=0
RUN if [ "${ENABLE_XDEBUG}" = "1" ]; then pecl install xdebug && docker-php-ext-enable xdebug; fi

# Compléments propres au projet, tous désactivés par défaut. Le projet les pose dans
# services.php.build.args de ses fichiers .docker/docker-compose[.prod].project.yml (versionnés),
# jamais dans .docker/.env (non synchronisé au déploiement, comme la version PHP).

# Couverture de code (PHPUnit --coverage) sans le coût d'Xdebug.
ARG ENABLE_PCOV=0
RUN if [ "${ENABLE_PCOV}" = "1" ]; then pecl install pcov && docker-php-ext-enable pcov; fi

# wkhtmltopdf 0.12.6.1 à Qt patché (paquet officiel, amd64) : /usr/local/bin/wkhtmltopdf.
# Le paquet bookworm s'installe tel quel sur la Debian de l'image ; apt résout ses dépendances.
ARG ENABLE_WKHTMLTOPDF=0
ARG WKHTMLTOPDF_DEB=https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb
RUN if [ "${ENABLE_WKHTMLTOPDF}" = "1" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends \
            libxrender1 libfontconfig1 libxext6 libx11-6 xfonts-base xfonts-75dpi fontconfig \
        && curl -sSLo /tmp/wkhtmltox.deb "${WKHTMLTOPDF_DEB}" \
        && apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb \
        && rm -rf /tmp/wkhtmltox.deb /var/lib/apt/lists/* \
        && wkhtmltopdf --version; \
    fi

# Paquets système et extensions PECL du projet, séparés par des espaces, ex.
# EXTRA_APT_PACKAGES="librabbitmq-dev libmagickwand-dev ghostscript poppler-utils"
# EXTRA_PECL_EXTENSIONS="amqp imagick" (version possible : redis-6.2.0). Installées puis activées.
ARG EXTRA_APT_PACKAGES=""
ARG EXTRA_PECL_EXTENSIONS=""
RUN if [ -n "${EXTRA_APT_PACKAGES}" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends ${EXTRA_APT_PACKAGES} \
        && rm -rf /var/lib/apt/lists/*; \
    fi \
    && if [ -n "${EXTRA_PECL_EXTENSIONS}" ]; then \
        for ext in ${EXTRA_PECL_EXTENSIONS}; do \
            printf '\n' | pecl install "${ext}" && docker-php-ext-enable "${ext%%-*}" || exit 1; \
        done; \
        rm -rf /tmp/pear; \
    fi

RUN groupadd -g "${GID}" devgroup && useradd -u "${UID}" -g "${GID}" -m -s /bin/bash devuser

USER devuser
WORKDIR /var/www
EXPOSE 9000
CMD ["php-fpm"]
