# syntax=docker/dockerfile:1

ARG PHP_VERSION=8.4
ARG NODE_VERSION=22

############################################
# Node (solo para copiar el binario)
############################################
FROM node:${NODE_VERSION}-alpine AS node-bin

############################################
# 1) BASE: PHP-FPM + extensiones + Composer
############################################
FROM php:${PHP_VERSION}-fpm-alpine AS php-base

COPY --from=mlocati/php-extension-installer:latest /usr/bin/install-php-extensions /usr/local/bin/

# Extensiones para Laravel + MySQL/MariaDB + imágenes
RUN install-php-extensions pdo_mysql mbstring intl zip gd bcmath pcntl exif opcache

RUN apk add --no-cache bash git unzip curl

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY docker/php/php-common.ini /usr/local/etc/php/conf.d/zz-common.ini

# El usuario www-data del contenedor adopta el UID/GID del usuario del host.
# Así los archivos creados en el contenedor (storage, vendor, etc.) son tuyos.
# "-o" permite UID/GID ya usados (p. ej. GID 20 en macOS).
ARG UID=1000
ARG GID=1000
RUN apk add --no-cache shadow \
    && groupmod -o -g ${GID} www-data \
    && usermod -o -u ${UID} -g ${GID} www-data \
    && apk del shadow

WORKDIR /var/www/html


############################################
# 2) PHP + NODE (desarrollo)
############################################
FROM php-base AS php-node

# Node oficial (necesario >= 22.13 si tu proyecto usa "php artisan dev" en Laravel 13.25+)
RUN apk add --no-cache libstdc++ libgcc
COPY --from=node-bin /usr/local/bin/node /usr/local/bin/node
COPY --from=node-bin /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx


############################################
# 3) DEV: un único contenedor con todo
############################################
FROM php-node AS dev

# Cachés en /tmp: el usuario www-data no tiene HOME escribible
ENV COMPOSER_HOME=/tmp/composer \
    npm_config_cache=/tmp/npm-cache

COPY docker/php/dev-entrypoint.sh /usr/local/bin/dev-entrypoint
RUN chmod +x /usr/local/bin/dev-entrypoint

USER www-data
EXPOSE 8000 5173

ENTRYPOINT ["dev-entrypoint"]
CMD ["composer", "run", "dev"]


############################################
# 4) FRONTEND (variante con Wayfinder): necesita PHP durante el build
############################################
FROM php-node AS frontend

WORKDIR /app

COPY composer.json composer.lock ./
RUN composer install --no-scripts --no-autoloader --prefer-dist --no-interaction

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN composer dump-autoload --no-scripts \
    && cp .env.example .env \
    && php artisan key:generate \
    && npm run build
# Resultado: /app/public/build (assets con hash + manifest.json)


############################################
# 5) PROD: PHP-FPM con código, vendor y assets
############################################
FROM php-base AS prod

ENV COMPOSER_ALLOW_SUPERUSER=1

COPY docker/php/opcache-prod.ini /usr/local/etc/php/conf.d/zz-opcache.ini

# Dependencias PHP (sin dev), aprovechando la caché de capas
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-interaction

# Código de la aplicación
COPY . .

# Assets compilados (con propietario www-data = tu UID, para poder copiarlos al host después)
COPY --from=frontend --chown=www-data:www-data /app/public/build ./public/build

RUN composer dump-autoload --optimize --classmap-authoritative --no-dev --no-scripts \
    && chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R ug+rwX storage bootstrap/cache

USER www-data
EXPOSE 9000
# CMD heredado de php-fpm: escucha en 0.0.0.0:9000 (dentro del contenedor)