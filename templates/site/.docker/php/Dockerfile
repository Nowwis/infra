ARG PHP_VERSION=8.4
FROM php:${PHP_VERSION}-fpm

ARG UID=1000
ARG GID=1000

# Extensions communes à Symfony, WordPress et PrestaShop 9 (gd, intl, zip, pdo_mysql, mysqli,
# exif, bcmath, opcache) ; pcntl : arrêt propre du worker Messenger sur SIGTERM.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git unzip curl \
        libzip-dev libpng-dev libfreetype6-dev libjpeg62-turbo-dev libwebp-dev libicu-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql mysqli zip gd intl exif bcmath opcache pcntl \
    && rm -rf /var/lib/apt/lists/*

ARG COMPOSER_VERSION=2
RUN curl -sS https://getcomposer.org/installer \
    | php -- --install-dir=/usr/local/bin --filename=composer --${COMPOSER_VERSION}

ARG ENABLE_XDEBUG=0
RUN if [ "${ENABLE_XDEBUG}" = "1" ]; then pecl install xdebug && docker-php-ext-enable xdebug; fi

RUN groupadd -g "${GID}" devgroup && useradd -u "${UID}" -g "${GID}" -m -s /bin/bash devuser

USER devuser
WORKDIR /var/www
EXPOSE 9000
CMD ["php-fpm"]
