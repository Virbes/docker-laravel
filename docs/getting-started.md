# Guía v2: Dockerizar un monolito Laravel + Inertia (React TSX) con BD externa y Nginx en el host

> **Esta versión reemplaza a la anterior.** Incorpora tres decisiones de arquitectura:
>
> 1. La base de datos (MySQL u otra) es un **servicio externo dedicado**: no corre en Docker.
> 2. **Un solo Nginx en el servidor** atiende todos los proyectos: no corre en Docker.
> 3. Los proyectos son **monolitos**: React TSX vive dentro de Laravel mediante **Inertia**.
>
> **Stack:** Laravel 12+ · PHP 8.4 · Inertia + React TSX · TypeScript · Vite · MySQL externo · Nginx del host.

---

## Índice

0. [Qué cambia respecto a la versión anterior](#0-qué-cambia-respecto-a-la-versión-anterior)
1. [Arquitectura](#1-arquitectura)
2. [Requisitos y verificación](#2-requisitos-y-verificación)
3. [Preparar la base de datos externa](#3-preparar-la-base-de-datos-externa)
4. [Estructura de archivos](#4-estructura-de-archivos)
5. [Paso 1 – `.dockerignore`](#paso-1--dockerignore)
6. [Paso 2 – Configuración de PHP](#paso-2--configuración-de-php)
7. [Paso 3 – `Dockerfile` multi-stage](#paso-3--dockerfile-multi-stage)
8. [Paso 4 – Entrypoint de desarrollo](#paso-4--entrypoint-de-desarrollo)
9. [Paso 5 – `docker-compose.yml` (desarrollo)](#paso-5--docker-composeyml-desarrollo)
10. [Paso 6 – Variables de entorno (desarrollo)](#paso-6--variables-de-entorno-desarrollo)
11. [Paso 7 – Ajustar Vite](#paso-7--ajustar-vite)
12. [Paso 8 – Elegir el comando de arranque (`composer run dev` / `artisan dev`)](#paso-8--elegir-el-comando-de-arranque)
13. [Paso 9 – Construir, inicializar y levantar (desarrollo)](#paso-9--construir-inicializar-y-levantar-desarrollo)
14. [Paso 10 – Verificación de desarrollo](#paso-10--verificación-de-desarrollo)
15. [Paso 11 – Producción: `docker-compose.prod.yml`](#paso-11--producción-docker-composeprodyml)
16. [Paso 12 – Nginx del host (un vhost por proyecto)](#paso-12--nginx-del-host-un-vhost-por-proyecto)
17. [Paso 13 – Script de despliegue y primer despliegue](#paso-13--script-de-despliegue-y-primer-despliegue)
18. [Paso 14 – Varios proyectos en el mismo servidor](#paso-14--varios-proyectos-en-el-mismo-servidor)
19. [Paso 15 – Respaldos](#paso-15--respaldos)
20. [Comandos del día a día](#comandos-del-día-a-día)
21. [Solución de problemas](#solución-de-problemas)
22. [Checklist final](#checklist-final)

---

## 0. Qué cambia respecto a la versión anterior

**Respuesta corta a "¿afecta en algo?": sí, en desarrollo y en despliegue.** Resumen:

| Tema | Antes | Ahora | Consecuencia |
|---|---|---|---|
| **MySQL** | Contenedor `db` | Servidor externo (dev: XAMPP/WAMP en tu equipo; prod: servidor dedicado) | Se elimina el servicio `db`, su volumen, su healthcheck y sus backups. `DB_HOST` cambia. Hay que preparar usuarios, permisos y red en el servidor de BD. |
| **Nginx** | Contenedor `web` | Nginx del host, compartido por todos los proyectos | Se elimina el servicio y la etapa `web`. El contenedor solo ejecuta **PHP-FPM** y lo publica en `127.0.0.1:PUERTO`. Los archivos estáticos (`public/build`) deben existir **en el host**. |
| **Frontend** | Servicio `node` separado | Monolito Inertia: **un solo contenedor** con PHP + Node | En desarrollo corre `composer run dev` (server + queue + Vite) en un único contenedor. |
| **Servidor web en dev** | Nginx + PHP-FPM | `php artisan serve` + Vite (igual que hoy sin Docker) | Menos piezas; el flujo diario no cambia. |
| **Backups de BD** | Parte de esta guía | Responsabilidad del servidor de BD | Aquí solo se respalda `storage/` y `.env`. |

### Lo que sí aporta tener la BD fuera de Docker

- Los datos sobreviven a cualquier `docker compose down -v`.
- Se puede respaldar, monitorear y escalar la BD de forma independiente.
- En desarrollo, **todos tus proyectos comparten una sola instancia de MySQL** (la de XAMPP/WAMP) con una BD y un usuario por proyecto, igual que en el servidor dedicado.

### Lo que hay que cuidar (riesgos nuevos)

- **Red y permisos:** el contenedor debe llegar al servidor de BD y el usuario de BD debe permitir conexiones desde donde llega el contenedor (ver [sección 3](#3-preparar-la-base-de-datos-externa)).
- **Paridad de motor:** XAMPP trae **MariaDB**, no MySQL. Si producción usa MySQL 8, hay diferencias (ver sección 3.3).
- **FastCGI sin autenticación:** el puerto de PHP-FPM **solo** puede publicarse en `127.0.0.1` (ver paso 11).

---

## 1. Arquitectura

### Desarrollo

```
Navegador ──► http://localhost:8000 ──► [ app: php artisan serve ]──┐
          └─► http://localhost:5173 ──► [ app: Vite (HMR) ]         ├─ mismo contenedor
                                        [ app: queue:listen ]───────┘
                                              │
                                              └─ host.docker.internal:3306 ──► MySQL de XAMPP/WAMP (tu equipo)
```

Un único contenedor `app` (PHP 8.3 + Node 22 + Composer) ejecuta lo mismo que ejecutas hoy a mano.

### Producción

```
Internet ─► [ Nginx del HOST ] ──static──► /srv/proyectos/mi-proyecto/public   (archivos del host)
                  │
                  └─FastCGI─► 127.0.0.1:9001 ─► [ contenedor app: PHP-FPM ] ──► Servidor de BD dedicado
                                                [ contenedor queue ]
                                                [ contenedor scheduler ]
```

- Nginx sirve los estáticos directamente desde el host y delega solo `index.php` al contenedor.
- Cada proyecto usa un puerto FPM distinto (9001, 9002, …).
- Los contenedores **no** contienen Nginx ni MySQL.

> 💡 **Alternativa (no usada aquí):** meter un servidor HTTP dentro del contenedor (p. ej. FrankenPHP) y que el Nginx del host haga `proxy_pass`. Evita sincronizar `public/build` al host, pero añade otro componente. Esta guía usa FPM porque respeta "Nginx del host para todos".

---

## 2. Requisitos y verificación

### 2.1 Docker

- **Linux (servidor):** Docker Engine + plugin Compose v2 → <https://docs.docker.com/engine/install/>
- **Windows (desarrollo con WAMP/XAMPP):** Docker Desktop con **WSL2**. Guarda el proyecto **dentro de WSL2** (por ejemplo `~/proyectos/mi-app`), no en `C:\`: es mucho más rápido y evita problemas de saltos de línea y permisos.
- **macOS:** Docker Desktop.

```bash
docker --version
docker compose version
docker run --rm hello-world
```

**Respuesta esperada:**

```
Docker version 27.x.x, build xxxxxxx
Docker Compose version v2.x.x
...
Hello from Docker!
```

> ⚠️ Usa `docker compose` (con espacio), no el antiguo `docker-compose`.

### 2.2 Verificar el proyecto

Desde la raíz (donde está `artisan`):

```bash
ls
```

**Debes ver:** `app/  artisan  composer.json  package.json  vite.config.ts  resources/  public/  .env.example` y los archivos `composer.lock` y `package-lock.json` (ambos deben estar versionados).

Comprueba la versión de Laravel y si usas Wayfinder/SSR (lo necesitarás más adelante):

```bash
grep -E '"laravel/framework"' composer.json
grep -iE 'wayfinder|ssr' package.json composer.json
```

---

## 3. Preparar la base de datos externa

### 3.1 Principios (dev y prod)

1. **Una base de datos y un usuario por proyecto.** Nunca uses `root` en la aplicación.
2. El usuario solo tiene privilegios sobre **su** base de datos.
3. Charset `utf8mb4` y collation `utf8mb4_unicode_ci` (el valor por defecto de Laravel para MySQL).

### 3.2 SQL para crear la BD y el usuario

Ejecútalo en el servidor de BD (phpMyAdmin → pestaña **SQL**, o `mysql -u root -p`):

```sql
CREATE DATABASE mi_proyecto CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- DESARROLLO: '%' permite conexiones desde Docker (ver explicación abajo)
CREATE USER 'mi_proyecto_app'@'%' IDENTIFIED BY 'cambia_esta_clave';
GRANT ALL PRIVILEGES ON mi_proyecto.* TO 'mi_proyecto_app'@'%';
FLUSH PRIVILEGES;
```

**Respuesta esperada:** `Query OK, 1 row affected` / `Query OK, 0 rows affected` en cada sentencia.

> 💡 **¿Por qué `'%'` y no `'localhost'`?** Desde un contenedor, MySQL ve la conexión llegando desde la IP de la red de Docker (por ejemplo `172.18.0.1`), **no** desde `localhost`. Un usuario creado solo para `'localhost'` falla con `Host '172.x.x.x' is not allowed to connect`.

### 3.3 Desarrollo: MySQL de XAMPP o WAMP

**a) ¿Es MySQL o MariaDB?** Ejecuta en phpMyAdmin o en el cliente:

```sql
SELECT VERSION();
```

| Resultado | Motor | Qué hacer |
|---|---|---|
| `8.4.x` / `8.0.x` | MySQL | Ideal si producción también es MySQL 8. |
| `10.x.x-MariaDB` (típico de **XAMPP**) | MariaDB | Usa `DB_CONNECTION=mariadb` en `.env`. Ojo con diferencias de collation (`utf8mb4_0900_ai_ci` no existe en MariaDB), tipo `JSON` y funciones nuevas de MySQL 8. Valida las migraciones contra el motor real de producción antes de liberar. |

> 💡 Si producción es MySQL 8 y quieres paridad real, instala MySQL Community 8.x en tu equipo (o usa la opción MySQL de WAMP) en lugar de MariaDB.

**b) Permitir conexiones desde Docker.**

1. Abre el `my.ini` (XAMPP: `C:\xampp\mysql\bin\my.ini`; WAMP: desde el menú de WAMP → MySQL → `my.ini`).
2. Asegúrate de que **no** exista `bind-address = 127.0.0.1` ni `skip-networking`. Si existe `bind-address`, cámbialo a `0.0.0.0`.
3. Reinicia MySQL desde el panel de XAMPP/WAMP.
4. **Firewall de Windows:** permite conexiones entrantes al puerto `3306` (solo en red privada). Si no, el contenedor verá `Connection timed out`.

> ⚠️ Con `0.0.0.0` MySQL queda accesible desde tu red local. Mantén `root` sin acceso remoto (solo los usuarios por proyecto con `'%'`), usa claves fuertes y limita el firewall a tu máquina o subred si es posible.

**c) Puerto:** XAMPP/WAMP usan `3306` por defecto. Si tienes otro MySQL ocupando ese puerto, anota el real y úsalo en `DB_PORT`.

### 3.4 Producción: servidor dedicado

Coordina con quien administra el servidor de BD:

| Requisito | Detalle |
|---|---|
| **Usuario por IP** | Crear el usuario restringido a la IP del servidor de aplicaciones: `CREATE USER 'mi_proyecto_app'@'10.0.0.5' ...` (la IP que el servidor de BD ve al conectarse; **no** uses `'%'` en producción). |
| **Firewall** | Abrir `3306/tcp` del servidor de BD **solo** hacia la IP del servidor de aplicaciones. |
| **Privilegios** | `ALL` sobre su BD, o separar un usuario de migraciones (DDL) y otro de runtime (DML) si la política lo exige. |
| **TLS** | Recomendado. Monta el certificado CA en el contenedor y define `MYSQL_ATTR_SSL_CA` en el `.env`. |
| **Límites** | Revisar `max_connections` si hay muchos proyectos/workers conectándose. |
| **Zona horaria / charset** | Alinear con `config/app.php` y la collation del paso 3.2. |
| **Respaldos** | Los gestiona el servidor de BD (ver [Paso 15](#paso-15--respaldos)). |

Verifica desde el **servidor de aplicaciones** (no desde el contenedor) que llegas a la BD:

```bash
nc -zv 10.0.0.20 3306
```

**Respuesta esperada:** `Connection to 10.0.0.20 3306 port [tcp/mysql] succeeded!`

---

## 4. Estructura de archivos

Archivos que se **agregan** a la raíz del proyecto:

```
mi-proyecto/
├── docker/
│   └── php/
│       ├── php-common.ini        # Ajustes generales de PHP
│       ├── opcache-prod.ini      # OPcache (solo producción)
│       └── dev-entrypoint.sh     # Prepara dependencias al iniciar en desarrollo
├── scripts/
│   └── deploy.sh                 # Despliegue en el servidor
├── Dockerfile                    # Etapas: dev y prod
├── docker-compose.yml            # Desarrollo
├── docker-compose.prod.yml       # Producción
├── .dockerignore
└── .gitattributes                # Fuerza saltos de línea LF en .sh
```

```bash
mkdir -p docker/php scripts
```

> No hay carpeta `docker/nginx` ni servicio de base de datos: Nginx y MySQL son externos.

---

## Paso 1 – `.dockerignore`

Evita enviar archivos innecesarios (o secretos) al build.

```gitignore
# Control de versiones
.git
.gitignore
.gitattributes

# Dependencias (se instalan dentro de la imagen)
vendor
node_modules

# Secretos y config local (NUNCA dentro de la imagen)
.env
.env.*
!.env.example

# Generados / temporales
public/build
public/hot
public/storage
bootstrap/ssr
bootstrap/cache/*.php
storage/logs/*
storage/framework/cache/data/*
storage/framework/sessions/*
storage/framework/views/*

# IDE y SO
.idea
.vscode
.DS_Store
Thumbs.db

# Docker
Dockerfile
docker-compose*.yml
.dockerignore
```

Crea también `.gitattributes` (evita que Windows convierta `dev-entrypoint.sh` a CRLF, lo que rompe el script dentro del contenedor):

```gitattributes
*.sh text eol=lf
```

---

## Paso 2 – Configuración de PHP

`docker/php/php-common.ini` (todos los entornos):

```ini
memory_limit = 256M
upload_max_filesize = 50M
post_max_size = 50M
max_execution_time = 120
date.timezone = America/Mexico_City
expose_php = Off
```

`docker/php/opcache-prod.ini` (solo producción):

```ini
opcache.enable = 1
opcache.memory_consumption = 192
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
; El código en la imagen es inmutable: no hace falta revisar cambios en disco
opcache.validate_timestamps = 0
```

> ⚠️ Alinea `upload_max_filesize`/`post_max_size` con `client_max_body_size` del Nginx del host (paso 12).

---

## Paso 3 – `Dockerfile` multi-stage

| Etapa | Base | Función |
|---|---|---|
| `node-bin` | `node:22-alpine` | Solo se usa para copiar el binario de Node |
| `php-base` | `php:8.3-fpm-alpine` | PHP + extensiones + Composer + usuario con tu UID |
| `php-node` | `php-base` | `php-base` + Node (para desarrollo) |
| `dev` | `php-node` | Imagen de desarrollo (código por bind mount) |
| `frontend` | `node-bin` | Compila React/TS con Vite (solo en el build de producción) |
| `prod` | `php-base` | Imagen final de producción (PHP-FPM, sin Node) |

Crea `Dockerfile`:

```dockerfile
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

COPY --from=ghcr.io/mlocati/php-extensions-installer:latest /usr/bin/install-php-extensions /usr/local/bin/

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
# 4) FRONTEND: compila React TSX (Inertia) con Vite
############################################
FROM node-bin AS frontend

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build
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
```

### Qué hace lo importante

- **`php-node`:** copia el binario oficial de Node en lugar de usar `apk add nodejs`, para controlar la versión exacta (`NODE_VERSION`).
- **`ARG UID/GID` + `usermod`:** evita archivos con dueño `root` o permisos raros en tu carpeta.
- **`CMD ["composer","run","dev"]`:** en desarrollo ejecuta el mismo script que usas hoy (`composer run dev`).
- **`frontend` + `COPY --from=frontend`:** el frontend se compila **durante el build**; en producción no hay Node en la imagen.
- **`--no-scripts`:** evita ejecutar `artisan` durante el build; Laravel regenera su manifiesto de paquetes al ejecutar `optimize`.

### ⚠️ Si tu proyecto usa Wayfinder

Algunas versiones del starter kit React de Laravel incluyen **Wayfinder**, que ejecuta `php artisan` durante `npm run build`. Si el build falla con `php: not found`, reemplaza la etapa `frontend` por esta (usa la imagen con PHP + Node):

```dockerfile
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
```

> En **desarrollo** no hace falta nada especial: PHP y Node viven en el mismo contenedor, así que el plugin de Wayfinder funciona tal cual.

### ⚠️ Si usas Inertia SSR

Esta guía **no** cubre SSR (`npm run build:ssr`, `inertia:start-ssr`). Con SSR, producción necesita Node en tiempo de ejecución y un proceso adicional. Si lo usas, avísame y se agrega como una sección aparte.

---

## Paso 4 – Entrypoint de desarrollo

`docker/php/dev-entrypoint.sh`:

```sh
#!/bin/sh
set -e

if [ ! -f .env ]; then
  echo "✗ No existe .env. Ejecuta primero: cp .env.example .env" >&2
  exit 1
fi

if [ ! -f vendor/autoload.php ]; then
  echo "→ Instalando dependencias PHP (composer install)..."
  composer install --no-interaction --prefer-dist
fi

if [ ! -d node_modules/.bin ]; then
  echo "→ Instalando dependencias JS (npm install)..."
  npm install
fi

exec "$@"
```

**Qué hace:** antes de ejecutar el comando principal, instala `vendor/` y `node_modules/` **solo si faltan**. Así `docker compose up` funciona en un clon recién descargado. `exec "$@"` ejecuta el comando del contenedor (`composer run dev`).

---

## Paso 5 – `docker-compose.yml` (desarrollo)

```yaml
name: mi-proyecto   # ⚠️ Cámbialo por el nombre del proyecto

services:
  app:
    build:
      context: .
      target: dev
      args:
        UID: ${DOCKER_UID:-1000}
        GID: ${DOCKER_GID:-1000}
    command: composer run dev
    ports:
      - "${APP_PORT:-8000}:8000"     # Laravel (artisan serve)
      - "${VITE_PORT:-5173}:5173"    # Vite (HMR)
    environment:
      SERVER_HOST: 0.0.0.0           # artisan serve debe escuchar fuera del contenedor
    extra_hosts:
      - "host.docker.internal:host-gateway"   # Llegar al MySQL del host (Linux, Windows y macOS)
    volumes:
      - .:/var/www/html              # Código en vivo; Laravel lee su .env desde aquí
```

| Fragmento | Qué hace |
|---|---|
| `target: dev` | Construye solo hasta la etapa `dev`. |
| `command: composer run dev` | Ejecuta el script `dev` de tu `composer.json` (server + queue + Vite). |
| `SERVER_HOST: 0.0.0.0` | Por defecto `artisan serve` escucha en `127.0.0.1` y **no** sería accesible desde tu navegador. |
| `extra_hosts ... host-gateway` | Hace que `host.docker.internal` resuelva al host. Docker Desktop ya lo trae; en Linux es necesario. |
| `.:/var/www/html` | Bind mount: tus cambios se reflejan al instante. `vendor/` y `node_modules/` quedan en tu carpeta (tu editor tiene autocompletado). |
| *(sin `env_file`)* | Laravel lee `.env` directamente del bind mount. Así los cambios de `.env` aplican sin recrear el contenedor. |

> ⚠️ **No ejecutes `npm install` en tu equipo si tu SO no es el del contenedor** (p. ej. Windows nativo): los binarios nativos (`rollup`, `esbuild`) son distintos por plataforma. Usa siempre `docker compose exec app npm ...`. Si ya lo hiciste, borra `node_modules` y deja que el contenedor lo reinstale.

---

## Paso 6 – Variables de entorno (desarrollo)

```bash
cp .env.example .env
```

Edita el `.env`:

```dotenv
APP_NAME="Mi Proyecto"
APP_ENV=local
APP_DEBUG=true
APP_URL=http://localhost:8000

# --- Puertos publicados en tu equipo ---
APP_PORT=8000
VITE_PORT=5173

# --- UID/GID para que los archivos sean tuyos (ver comando abajo) ---
DOCKER_UID=1000
DOCKER_GID=1000

# --- Base de datos EXTERNA (XAMPP/WAMP en tu equipo) ---
DB_CONNECTION=mysql              # usa "mariadb" si tu servidor es MariaDB (XAMPP)
DB_HOST=host.docker.internal     # ⚠️ el MySQL de TU EQUIPO visto desde el contenedor
DB_PORT=3306
DB_DATABASE=mi_proyecto
DB_USERNAME=mi_proyecto_app
DB_PASSWORD=cambia_esta_clave

# --- Laravel 12 usa la BD para sesión, caché y colas por defecto ---
SESSION_DRIVER=database
CACHE_STORE=database
QUEUE_CONNECTION=database
```

Ajusta tu UID/GID reales (Linux/WSL/macOS):

```bash
sed -i "s/^DOCKER_UID=.*/DOCKER_UID=$(id -u)/; s/^DOCKER_GID=.*/DOCKER_GID=$(id -g)/" .env
grep DOCKER_ .env
```

**Respuesta esperada:** `DOCKER_UID=1000` y `DOCKER_GID=1000` (o tus valores). En macOS, `sed -i` requiere `sed -i ''`.

> ⚠️ **Errores clásicos:**
> - `DB_HOST=127.0.0.1` → dentro del contenedor es **el propio contenedor**, no tu MySQL. Debe ser `host.docker.internal`.
> - Si tu clave contiene `$`, enciérrala entre comillas simples: `DB_PASSWORD='ab$cd'`.
> - Si cambias `APP_PORT` (p. ej. `8080`), ajusta también `APP_URL` a ese puerto.

---

## Paso 7 – Ajustar Vite

Vite corre dentro del contenedor, pero tu navegador (en el host) se conecta a él. Edita `vite.config.ts` **conservando tus `input` y plugins**, y agrega el bloque `server`:

```ts
import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';
import react from '@vitejs/plugin-react';

export default defineConfig({
    plugins: [
        laravel({
            input: ['resources/css/app.css', 'resources/js/app.tsx'],
            refresh: true,
        }),
        react(),
    ],
    server: {
        host: '0.0.0.0',          // Escuchar fuera del contenedor
        port: 5173,
        strictPort: true,
        hmr: {
            host: 'localhost',    // Donde el NAVEGADOR encuentra a Vite
        },
        // watch: { usePolling: true },  // Solo si el proyecto está en /mnt/c (Windows) y no detecta cambios
    },
});
```

> 💡 Con Inertia el navegador carga la página desde `:8000` y los assets de Vite desde `:5173` (Laravel lo resuelve con el archivo `public/hot`). Por eso ambos puertos están publicados.

---

## Paso 8 – Elegir el comando de arranque

Hoy arrancas el proyecto con `composer run dev`, `php artisan dev` o por separado. En el contenedor, el comando se define en `command:` del compose. Lo importante es **qué hace el script `dev` de tu `composer.json`**:

| Tu proyecto | Qué ejecuta | ¿Necesita algo especial en Docker? |
|---|---|---|
| Script antiguo: `npx concurrently ... "php artisan serve" "php artisan queue:listen --tries=1" "npm run dev"` | Server + queue + Vite | No. `SERVER_HOST=0.0.0.0` es suficiente. |
| Laravel 13.16+ con `php artisan dev` (el script `composer run dev` solo lo invoca) | Server + queue + logs (Pail) + Vite | **Depende de la versión**, ver abajo. |

**Sobre `php artisan dev`** (comando nuevo de Laravel 13):

- **Laravel 13.25 o superior:** respeta `SERVER_HOST`, así que funciona con la configuración de esta guía. Además usa una UI en pestañas que requiere **Node ≥ 22.13** (la imagen incluye Node 22) y un TTY; dentro de Docker, sin TTY, cambia automáticamente a modo *inline* (salida de texto plano). Descarga `@laravel/multiplex` con `npx` la primera vez, así que el contenedor necesita salida a internet.
- **Laravel 13.16 a 13.24:** el proceso `server` se registraba como `serve --host=localhost` e **ignoraba `SERVER_HOST`**, por lo que `http://localhost:8000` no abriría desde tu navegador. Soluciones: actualizar a ≥ 13.25 (`composer update laravel/framework`) o registrar el proceso `server` a mano:

  ```php
  // app/Providers/AppServiceProvider.php
  use Illuminate\Foundation\DevCommands;

  public function boot(): void
  {
      if ($this->app->environment('local')) {
          DevCommands::artisan('serve --host=0.0.0.0 --port=8000', 'server');
      }
  }
  ```

  (Según la documentación de Laravel 13; verifica contra tu versión exacta.)
- **Laravel 12:** no existe `artisan dev`; usa `composer run dev`.

**Recomendación:** deja `command: composer run dev` en el compose. Ejecuta lo que defina tu proyecto, sea el script antiguo o `artisan dev`.

Para saber qué versión usas:

```bash
docker compose run --rm app php artisan --version
```

**Respuesta esperada:** `Laravel Framework 12.x.x` o `13.x.x`.

---

## Paso 9 – Construir, inicializar y levantar (desarrollo)

### 9.1 Validar el compose

```bash
docker compose config --quiet
```

**Respuesta esperada:** sin salida (éxito). Si hay error, indica la línea.

### 9.2 Construir la imagen

```bash
docker compose build
```

**Qué hace:** construye la etapa `dev` (PHP + extensiones + Node + Composer). La primera vez tarda varios minutos.

**Respuesta esperada (final):**

```
[+] Building 120.4s (19/19) FINISHED
 => [app] exporting to image
 => => naming to docker.io/library/mi-proyecto-app
```

Comprueba las versiones dentro de la imagen:

```bash
docker compose run --rm --entrypoint "" app sh -c "php -v | head -n1 && node -v && composer --version"
```

**Respuesta esperada (aprox.):**

```
PHP 8.3.x (cli) ...
v22.x.x
Composer version 2.x.x ...
```

### 9.3 Verificar que el contenedor alcanza tu MySQL

Antes de migrar, prueba solo la conectividad de red:

```bash
docker compose run --rm --entrypoint "" app php -r '$f=@fsockopen("host.docker.internal",3306,$e,$s,3); echo $f ? "OK: MySQL alcanzable\n" : "FALLO ($e): $s\n";'
```

**Respuesta esperada:** `OK: MySQL alcanzable`

Si falla, ver [Solución de problemas](#solución-de-problemas) (MySQL apagado, `bind-address`, firewall).

### 9.4 Dependencias, clave y migraciones

El entrypoint instala `vendor/` y `node_modules/` la primera vez que ejecutas cualquier comando:

```bash
docker compose run --rm app php artisan key:generate
```

**Respuesta esperada:**

```
→ Instalando dependencias PHP (composer install)...
...
→ Instalando dependencias JS (npm install)...
...
   INFO  Application key set successfully.
```

Comprueba la conexión con credenciales reales:

```bash
docker compose run --rm app php artisan db:show
```

**Respuesta esperada (resumida):**

```
  MySQL 8.x.x (o MariaDB 10.x.x) ..................... mysql
  Database ........................................ mi_proyecto
  Host ................................ host.docker.internal
  Port ................................................. 3306
```

Migra:

```bash
docker compose run --rm app php artisan migrate
```

**Respuesta esperada:**

```
   INFO  Preparing database.
  Creating migration table ......................... 12ms DONE
   INFO  Running migrations.
  0001_01_01_000000_create_users_table ............. 25ms DONE
  ...
```

(Opcional) seeders:

```bash
docker compose run --rm app php artisan db:seed
```

### 9.5 Levantar el proyecto

```bash
docker compose up
```

**Qué hace:** inicia `composer run dev` en primer plano (verás los logs de los procesos). `Ctrl+C` lo detiene. Para segundo plano usa `docker compose up -d` y `docker compose logs -f`.

**Respuesta esperada (aprox.):**

```
app-1  |   INFO  Server running on [http://0.0.0.0:8000].
app-1  |   VITE v7.x.x  ready in 600 ms
app-1  |   ➜  Local:   http://localhost:5173/
app-1  |   INFO  Processing jobs from the [default] queue.
```

---

## Paso 10 – Verificación de desarrollo

| # | Qué probar | Cómo | Resultado esperado |
|---|---|---|---|
| 1 | Laravel responde | Abre <http://localhost:8000> | Se ve tu aplicación Inertia (login/bienvenida). |
| 2 | HMR de React | Edita un texto en un `.tsx` y guarda | El navegador se actualiza **sin recargar**. |
| 3 | Conexión a BD | `docker compose exec app php artisan db:show` | Muestra host `host.docker.internal` y tus tablas. |
| 4 | Versión de Laravel | `docker compose exec app php artisan --version` | `Laravel Framework 12.x.x` o `13.x.x`. |
| 5 | Extensiones PHP | `docker compose exec app php -m` | Incluye `pdo_mysql`, `mbstring`, `intl`, `gd`, `zip`, `bcmath`, `pcntl`. |
| 6 | Colas | Despacha un Job y revisa los logs del servicio | El worker lo procesa (`DONE`). |
| 7 | Tipos TypeScript | `docker compose exec app npx tsc --noEmit` | Sin errores (o los errores propios del proyecto). |
| 8 | Permisos de escritura | `docker compose exec app sh -c "touch storage/logs/t.log && echo OK && rm storage/logs/t.log"` | `OK` |

✅ Con esto el entorno de **desarrollo** está dockerizado y conectado a la BD externa.

---

## Paso 11 – Producción: `docker-compose.prod.yml`

**Diferencias con desarrollo:**

- El código y el frontend compilado van **dentro de la imagen** (sin bind mounts del código).
- Solo hay **PHP-FPM** (más `queue` y `scheduler`); no hay Node, Nginx ni MySQL.
- El puerto FPM se publica **únicamente en `127.0.0.1`**.
- `storage/` y `.env` se montan desde el host.

```yaml
name: mi-proyecto-prod   # ⚠️ Único por proyecto

x-app-common: &app-common
  image: mi-proyecto/app:latest
  restart: unless-stopped
  volumes:
    - ./.env:/var/www/html/.env:ro          # Configuración y secretos (no están en la imagen)
    - ./storage:/var/www/html/storage       # Logs, uploads y caché; Nginx lee storage/app/public

services:
  app:
    <<: *app-common
    build:
      context: .
      target: prod
      args:
        UID: ${DOCKER_UID:-1000}
        GID: ${DOCKER_GID:-1000}
    ports:
      - "127.0.0.1:${FPM_PORT:-9001}:9000"  # ⚠️ SOLO localhost

  queue:
    <<: *app-common
    command: php artisan queue:work --tries=3 --timeout=90
    depends_on:
      - app

  scheduler:
    <<: *app-common
    command: php artisan schedule:work
    depends_on:
      - app
```

> 🚨 **Nunca** publiques `9000` como `"9001:9000"` (sin `127.0.0.1`). FastCGI no tiene autenticación: cualquiera que llegue a ese puerto podría pedirle a PHP-FPM que ejecute archivos del contenedor.

> 💡 Si no usas colas o tareas programadas, elimina los servicios `queue` y `scheduler`.

### `.env` de producción (en el servidor, **nunca** en Git)

```dockerfile
# (archivo .env, no un Dockerfile; se muestra como texto)
```

```dotenv
APP_NAME="Mi Proyecto"
APP_ENV=production
APP_DEBUG=false
APP_URL=https://mi-proyecto.empresa.com
APP_KEY=base64:...                 # ver "Primer despliegue" para generarla

LOG_CHANNEL=stack
LOG_LEVEL=warning

# --- Docker ---
DOCKER_UID=1001                    # UID del usuario que despliega (id -u)
DOCKER_GID=1001                    # GID del usuario que despliega (id -g)
FPM_PORT=9001                      # Único por proyecto en este servidor

# --- Base de datos EXTERNA (servidor dedicado) ---
DB_CONNECTION=mysql
DB_HOST=10.0.0.20                  # IP o hostname del servidor de BD
DB_PORT=3306
DB_DATABASE=mi_proyecto
DB_USERNAME=mi_proyecto_app
DB_PASSWORD='<clave-larga-y-unica>'   # Comillas simples si contiene "$"
# MYSQL_ATTR_SSL_CA=/ruta/al/ca.pem   # Si el servidor exige TLS (montar el CA en el contenedor)

SESSION_DRIVER=database
CACHE_STORE=database
QUEUE_CONNECTION=database
```

> 🔐 Usa claves **distintas** a las de desarrollo. Genera contraseñas con `openssl rand -base64 24`.

---

## Paso 12 – Nginx del host (un vhost por proyecto)

El Nginx del servidor sirve los estáticos desde el **host** y envía solo `index.php` al contenedor.

Crea `/etc/nginx/sites-available/mi-proyecto.conf`:

```nginx
server {
    listen 80;
    server_name mi-proyecto.empresa.com;

    # Carpeta public/ del proyecto EN EL HOST (git checkout + public/build extraído)
    root /srv/proyectos/mi-proyecto/public;
    index index.php;

    charset utf-8;
    client_max_body_size 50M;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    # Archivos subidos (Storage::disk('public')) → storage/app/public del host
    location /storage/ {
        alias /srv/proyectos/mi-proyecto/storage/app/public/;
        access_log off;
        expires 30d;
        try_files $uri =404;
    }

    # Único punto de entrada PHP → contenedor
    location = /index.php {
        fastcgi_pass 127.0.0.1:9001;                       # = FPM_PORT del proyecto
        include fastcgi_params;
        # Rutas DENTRO del contenedor (no las del host):
        fastcgi_param SCRIPT_FILENAME /var/www/html/public/index.php;
        fastcgi_param DOCUMENT_ROOT   /var/www/html/public;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 120s;
    }

    # Cualquier otro .php se rechaza (solo index.php se ejecuta)
    location ~ \.php$ {
        return 404;
    }

    # Estáticos compilados por Vite (nombres con hash → caché larga)
    location ^~ /build/ {
        access_log off;
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    # Bloquear archivos ocultos (.env, .git...)
    location ~ /\.(?!well-known).* {
        deny all;
    }
}
```

**Punto clave:** `root` apunta a la ruta del **host**, pero `SCRIPT_FILENAME` apunta a la ruta **dentro del contenedor** (`/var/www/html/public/index.php`). Si no coinciden con la ruta real del contenedor, PHP-FPM responde `File not found.`.

Activa el sitio y recarga:

```bash
sudo ln -s /etc/nginx/sites-available/mi-proyecto.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

**Respuesta esperada de `nginx -t`:**

```
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

HTTPS con Certbot:

```bash
sudo certbot --nginx -d mi-proyecto.empresa.com
```

> 💡 Como Nginx ahora entrega directo a PHP-FPM (no hay proxy HTTP intermedio), Laravel detecta HTTPS por el parámetro `HTTPS` de `fastcgi_params`. **Ya no necesitas `trustProxies`** para este caso.
>
> ⚠️ El usuario de Nginx (normalmente `www-data`) debe poder **entrar** a toda la ruta `/srv/proyectos/mi-proyecto/...`. Verifica con `namei -l /srv/proyectos/mi-proyecto/public/index.php` (cada carpeta debe tener `x` para "otros").

---

## Paso 13 – Script de despliegue y primer despliegue

### 13.1 `scripts/deploy.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE="docker compose -f docker-compose.prod.yml"
IMAGE="mi-proyecto/app:latest"     # ⚠️ Debe coincidir con "image:" del compose

echo "→ 1/7 Actualizando código"
git pull --ff-only origin main

echo "→ 2/7 Construyendo imagen (compila el frontend dentro del build)"
$COMPOSE build

echo "→ 3/7 Copiando assets compilados al host (public/build)"
mkdir -p public/build
cid=$(docker create "$IMAGE")
docker cp "$cid:/var/www/html/public/build/." ./public/build/
docker rm "$cid" > /dev/null

echo "→ 4/7 Recreando contenedores"
$COMPOSE up -d

echo "→ 5/7 Migraciones"
$COMPOSE exec -T app php artisan migrate --force

echo "→ 6/7 Cachés de Laravel"
$COMPOSE exec -T app php artisan optimize:clear
$COMPOSE exec -T app php artisan optimize

echo "→ 7/7 Reiniciando workers"
$COMPOSE restart queue scheduler

echo "✓ Despliegue completado"
```

```bash
chmod +x scripts/deploy.sh
```

**Qué hace cada paso:**

1. `git pull --ff-only` → trae el código nuevo y falla si hay divergencias (no hace merges sorpresa).
2. `build` → crea la imagen con el código y los assets de Vite.
3. `docker create` + `docker cp` → saca `public/build` de la imagen y lo **mezcla** en el host (se conservan los archivos con hash anteriores, así las páginas abiertas durante el deploy no dan 404). Los archivos quedan con tu UID porque la imagen usa `--chown=www-data` con tu UID.
4. `up -d` → recrea solo los contenedores cuya imagen cambió.
5. `migrate --force` → `--force` es obligatorio en producción.
6. `optimize:clear` + `optimize` → renueva las cachés de config, rutas y vistas.
7. `restart` → los workers cargan el código nuevo.

> 💡 `public/build` crece con cada deploy (archivos con hash viejos). Limpia periódicamente: `find public/build/assets -type f -mtime +30 -delete`.

### 13.2 Primer despliegue (checklist ordenado)

1. **Base de datos:** crear BD y usuario en el servidor dedicado ([sección 3.4](#34-producción-servidor-dedicado)) y verificar la conectividad con `nc -zv`.
2. **Clonar:**
   ```bash
   cd /srv/proyectos
   git clone <url-del-repo> mi-proyecto
   cd mi-proyecto
   ```
3. **Crear el `.env` de producción** (paso 11) y fijar tu UID/GID:
   ```bash
   cp .env.example .env
   sed -i "s/^DOCKER_UID=.*/DOCKER_UID=$(id -u)/; s/^DOCKER_GID=.*/DOCKER_GID=$(id -g)/" .env
   ```
   (Si `.env.example` no trae esas variables, agrégalas a mano.)
4. **Generar `APP_KEY`** (requiere construir la imagen una vez):
   ```bash
   docker compose -f docker-compose.prod.yml build
   docker compose -f docker-compose.prod.yml run --rm app php artisan key:generate --show
   ```
   **Respuesta esperada:** `base64:xxxxxxxx...` → pégala en `APP_KEY=` del `.env`.
5. **Ejecutar el despliegue:**
   ```bash
   ./scripts/deploy.sh
   ```
   **Respuesta esperada:** las 7 etapas y `✓ Despliegue completado`.
6. **Configurar Nginx y HTTPS** (paso 12).
7. **Verificar:**
   ```bash
   docker compose -f docker-compose.prod.yml ps
   ls public/build
   curl -I https://mi-proyecto.empresa.com
   ```
   **Respuestas esperadas:**
   ```
   NAME                      SERVICE     STATUS         PORTS
   mi-proyecto-prod-app-1    app         Up ...         127.0.0.1:9001->9000/tcp
   mi-proyecto-prod-queue-1  queue       Up ...
   mi-proyecto-prod-scheduler-1  scheduler  Up ...

   assets  manifest.json

   HTTP/2 200      (o 302 si redirige a login)
   ```
   Estado de la conexión a la BD:
   ```bash
   docker compose -f docker-compose.prod.yml exec app php artisan db:show
   ```

> ⚠️ Después de `optimize`, los cambios en `.env` **no** se reflejan hasta ejecutar `php artisan optimize:clear` + `optimize` (el script de deploy ya lo hace).

> 🚨 **Nunca** ejecutes `docker compose down -v` ni borres `./storage` en producción: contiene los archivos subidos por los usuarios.

---

## Paso 14 – Varios proyectos en el mismo servidor

Este es el objetivo de dockerizar: **cada proyecto aislado**, con un único Nginx compartido.

| Recurso | Regla |
|---|---|
| **`name:` de Compose** | Único por proyecto (`proyecto-a-prod`, `proyecto-b-prod`). |
| **Puerto FPM** (`FPM_PORT`) | Único por proyecto: 9001, 9002, 9003… siempre en `127.0.0.1`. |
| **Vhost de Nginx** | Un archivo por proyecto, con su `server_name`, su `root`, su `alias /storage/` y su `fastcgi_pass 127.0.0.1:<FPM_PORT>`. |
| **Imagen** | Nombre distinto por proyecto (`proyecto-a/app`, `proyecto-b/app`). |
| **Base de datos** | Una BD y un usuario por proyecto en el servidor dedicado, con acceso restringido a la IP de este servidor. |
| **`.env` y `storage/`** | Propios de cada proyecto, en su carpeta. |
| **Dependencias** | Cada imagen trae su propio PHP, extensiones y `vendor/`: proyectos con versiones distintas de PHP/Laravel conviven sin conflicto (cambia `PHP_VERSION` del Dockerfile por proyecto). |

Tabla de ejemplo:

| Proyecto | Carpeta | Dominio | `FPM_PORT` | BD |
|---|---|---|---|---|
| A | `/srv/proyectos/proyecto-a` | `a.empresa.com` | 9001 | `proyecto_a` |
| B | `/srv/proyectos/proyecto-b` | `b.empresa.com` | 9002 | `proyecto_b` |

Comprueba que no haya colisión de puertos:

```bash
sudo ss -ltnp | grep -E ':900[0-9]'
```

**Respuesta esperada:** una línea por proyecto, cada una con un puerto distinto en `127.0.0.1`.

---

## Paso 15 – Respaldos

Con la BD fuera de Docker, los respaldos de datos pasan a ser responsabilidad del servidor dedicado.

| Qué | Quién / cómo |
|---|---|
| **Base de datos** | Servidor de BD (mysqldump programado, snapshots o la herramienta que use la empresa). Acordar frecuencia, retención y **una restauración de prueba**. |
| **Archivos subidos** (`storage/app`) | Servidor de aplicaciones. |
| **`.env` de producción** | Guardado en el gestor de secretos de la empresa (no solo en el servidor). |
| **Código** | Git. |

Respaldo de archivos subidos:

```bash
tar czf /srv/backups/mi-proyecto_storage_$(date +%F).tar.gz -C /srv/proyectos/mi-proyecto storage/app
```

**Respuesta esperada:** sin salida; verifica con `ls -lh /srv/backups/` y `tar tzf <archivo> | head`.

Automatizar con cron (diario 3:00):

```cron
0 3 * * * tar czf /srv/backups/mi-proyecto_storage_$(date +\%F).tar.gz -C /srv/proyectos/mi-proyecto storage/app
```

> 💡 Copia los respaldos a **otro servidor o almacenamiento externo**: un backup en el mismo disco no protege contra la falla del disco.

---

## Comandos del día a día

### Desarrollo

| Necesidad | Comando |
|---|---|
| Levantar (con logs) | `docker compose up` |
| Levantar en segundo plano | `docker compose up -d` y `docker compose logs -f --tail=100` |
| Detener | `docker compose down` (no afecta la BD: es externa) |
| Reconstruir tras cambiar el Dockerfile | `docker compose build --no-cache app` |
| Artisan | `docker compose exec app php artisan <comando>` |
| Composer | `docker compose exec app composer require vendor/paquete` |
| npm | `docker compose exec app npm install <paquete>` |
| Tests | `docker compose exec app php artisan test` |
| Formateo (Pint) | `docker compose exec app ./vendor/bin/pint` |
| Tipos TS / lint | `docker compose exec app npx tsc --noEmit` · `docker compose exec app npm run lint` |
| Shell en el contenedor | `docker compose exec app bash` |
| Comando puntual sin levantar todo | `docker compose run --rm app php artisan tinker` |

> Si el contenedor no está corriendo, `exec` falla; usa `run --rm`.

### Producción

| Necesidad | Comando |
|---|---|
| Desplegar | `./scripts/deploy.sh` |
| Estado | `docker compose -f docker-compose.prod.yml ps` |
| Logs de la app | `docker compose -f docker-compose.prod.yml logs --tail=100 app` |
| Artisan | `docker compose -f docker-compose.prod.yml exec app php artisan <comando>` |
| Reiniciar workers | `docker compose -f docker-compose.prod.yml restart queue scheduler` |
| Limpiar imágenes viejas | `docker image prune -f` |

### Atajo opcional: `Makefile`

```makefile
.PHONY: up down logs shell migrate test

up:
	docker compose up

down:
	docker compose down

logs:
	docker compose logs -f --tail=100

shell:
	docker compose exec app bash

migrate:
	docker compose exec app php artisan migrate

test:
	docker compose exec app php artisan test
```

---

## Solución de problemas

### Base de datos

| Síntoma | Causa probable | Solución |
|---|---|---|
| `getaddrinfo for host.docker.internal failed` | Falta `extra_hosts` (Linux) | Agrega `extra_hosts: ["host.docker.internal:host-gateway"]` al servicio y recrea: `docker compose up -d --force-recreate`. |
| `SQLSTATE[HY000] [2002] Connection refused` / `timed out` | MySQL apagado, `bind-address=127.0.0.1`, firewall o puerto incorrecto | Enciende MySQL; revisa `my.ini` (sección 3.3); abre `3306` en el firewall; confirma `DB_PORT`. Reprueba con el chequeo del paso 9.3. |
| `Host '172.x.x.x' is not allowed to connect to this MySQL server` | El usuario solo existe para `'localhost'` | Crea el usuario con `'@'%'` (dev) o con la IP correcta (prod). |
| `SQLSTATE[HY000] [1045] Access denied for user` | Usuario/clave incorrectos o usuario con otro host | Revisa `DB_USERNAME`/`DB_PASSWORD` y `SELECT user, host FROM mysql.user;`. Si la clave tiene `$`, usa comillas simples. |
| `SQLSTATE[HY000] [1049] Unknown database` | La BD no existe | Créala (sección 3.2). |
| `Unknown collation: 'utf8mb4_0900_ai_ci'` o fallos con columnas `JSON` | Estás en MariaDB (XAMPP) con SQL pensado para MySQL 8 | Usa MySQL 8 en tu equipo o ajusta la collation; valida las migraciones contra el motor de producción. |
| Funciona en dev pero no en prod | Usuario con `'%'` en dev vs IP restringida en prod | Verifica la IP de origen que ve el servidor de BD y el firewall (sección 3.4). |

### Desarrollo (app y frontend)

| Síntoma | Causa probable | Solución |
|---|---|---|
| El contenedor está `Up` pero `localhost:8000` no abre | `artisan serve` escucha en `127.0.0.1` | Confirma `SERVER_HOST=0.0.0.0` en el compose. Si usas `artisan dev` en Laravel 13.16–13.24, ver paso 8. |
| `exec ... dev-entrypoint: no such file or directory` o `bad interpreter` | `dev-entrypoint.sh` con saltos de línea CRLF | Crea `.gitattributes` (`*.sh text eol=lf`), convierte el archivo a LF y reconstruye. |
| `✗ No existe .env` | Falta el `.env` | `cp .env.example .env`. |
| `Permission denied` en `storage/` o `bootstrap/cache` | UID/GID del contenedor ≠ el tuyo | Ajusta `DOCKER_UID`/`DOCKER_GID` en `.env` y `docker compose build --no-cache app`. |
| `EACCES` al hacer `npm install` o `composer install` | Cachés sin permisos | La imagen usa `/tmp` para cachés; reconstruye con `build --no-cache`. |
| Errores de `rollup`/`esbuild` por plataforma | `node_modules` instalado en el host de otro SO | Borra `node_modules` y deja que el contenedor lo reinstale. |
| HMR no funciona / errores de WebSocket | `server.hmr.host` mal o `5173` no publicado | Revisa paso 7 y el mapeo `5173:5173`. |
| Cambios de archivos no se detectan (proyecto en `/mnt/c`) | Sistema de archivos de Windows | Mueve el proyecto a WSL2 o activa `watch.usePolling`. |
| `Port is already allocated` | Puerto ocupado | Cambia `APP_PORT`/`VITE_PORT` en `.env` (y `APP_URL` si cambias `APP_PORT`). |
| `artisan dev` falla con un error de Node | Node menor a 22.13 | `docker compose run --rm --entrypoint "" app node -v` debe mostrar ≥ 22.13. |

### Producción (Nginx del host + PHP-FPM)

| Síntoma | Causa probable | Solución |
|---|---|---|
| **502 Bad Gateway** | Contenedor `app` caído o `fastcgi_pass` con puerto equivocado | `docker compose -f docker-compose.prod.yml ps` y `logs app`; el puerto debe coincidir con `FPM_PORT`. |
| Página en blanco con `File not found.` | `SCRIPT_FILENAME` no coincide con la ruta dentro del contenedor | Debe ser `/var/www/html/public/index.php` (paso 12). |
| **404 en CSS/JS** (`/build/...`) | `public/build` no está en el host | Ejecuta el paso 3 del deploy (`docker cp`) y revisa `ls public/build`. Verifica el `root` del vhost. |
| **403 Forbidden** en estáticos | Nginx no puede recorrer la ruta o leer los archivos | `namei -l /srv/proyectos/mi-proyecto/public/build/manifest.json`; da `x` a "otros" en las carpetas padre. |
| **404 en `/storage/...`** | `alias` incorrecto o falta el archivo | Verifica la ruta del `alias` (termina en `/`) y que el archivo exista en `storage/app/public`. |
| `Permission denied` al escribir logs/cachés | `storage/` del host con dueño distinto al `DOCKER_UID` | `sudo chown -R $(id -u):$(id -g) storage` y confirma `DOCKER_UID` antes de `build`. |
| `The stream or file ".../laravel.log" could not be opened` | Mismo caso anterior | Ídem. |
| Assets con URLs `http://` en un sitio HTTPS | `APP_URL` incorrecto o HTTPS sin configurar | Usa `APP_URL=https://...` y `optimize:clear` + `optimize`. |
| Cambios en `.env` no aplican | Config cacheada | `php artisan optimize:clear && php artisan optimize` y `restart queue scheduler`. |
| `Vite manifest not found` | Imagen construida sin frontend o build fallido | Revisa el log del build; reconstruye con `build --no-cache`. |
| Disco lleno | Imágenes y caché de build acumuladas | `docker image prune -f` y `docker builder prune -f`; revisa `docker system df`. |

**Diagnóstico general:**

```bash
docker compose ps                              # ¿Qué está arriba/caído?
docker compose logs --tail=100 <servicio>      # ¿Qué dice el error?
docker compose exec app php artisan about      # Resumen del entorno de Laravel
```

---

## Checklist final

### Base de datos
- [ ] BD y usuario por proyecto creados (no se usa `root`).
- [ ] Dev: MySQL de XAMPP/WAMP acepta conexiones externas (`bind-address`, firewall) y el usuario es `'@'%'`.
- [ ] Dev: se conoce el motor real (MySQL vs MariaDB) y se compara con producción.
- [ ] Prod: usuario restringido a la IP del servidor de aplicaciones; firewall abierto solo hacia esa IP; TLS si la política lo exige.

### Desarrollo
- [ ] `.dockerignore`, `.gitattributes`, `Dockerfile`, `docker-compose.yml` y carpeta `docker/` creados.
- [ ] `.env` con `DB_HOST=host.docker.internal`, `DOCKER_UID`/`DOCKER_GID` correctos y `APP_URL` acorde al puerto.
- [ ] `vite.config.ts` con el bloque `server` (host `0.0.0.0`, HMR host `localhost`).
- [ ] `docker compose run --rm app php artisan migrate` ejecutado sin errores.
- [ ] `docker compose up` → `localhost:8000` abre y el HMR funciona.
- [ ] Se conoce qué ejecuta el script `dev` del proyecto (paso 8).

### Producción
- [ ] `docker-compose.prod.yml` con `name`, `FPM_PORT` únicos y el puerto publicado **solo** en `127.0.0.1`.
- [ ] `.env` de producción con `APP_ENV=production`, `APP_DEBUG=false`, claves únicas, fuera de Git.
- [ ] Vhost de Nginx del host con `root`, `alias /storage/`, `fastcgi_pass` y `SCRIPT_FILENAME` correctos; `nginx -t` OK.
- [ ] HTTPS configurado (Certbot).
- [ ] `./scripts/deploy.sh` ejecutado: `migrate --force`, `optimize` y `public/build` presente en el host.
- [ ] Respaldos de BD acordados con el responsable del servidor dedicado y respaldo de `storage/app` programado.
- [ ] Nadie ejecuta `docker compose down -v` ni borra `storage/` en producción.

### Para el equipo
- [ ] `package-lock.json` y `composer.lock` versionados.
- [ ] Esta guía vive en el repositorio (por ejemplo `docs/docker.md`) y el `README` enlaza a ella.
- [ ] Cada proyecto nuevo parte de esta plantilla (Dockerfile + compose + `docker/` + `scripts/deploy.sh`).

---

*Versiones de referencia: PHP 8.3 · Laravel 12/13 · Node 22 · Docker Compose v2 · Nginx del host. Si tu proyecto usa otras versiones, cambia los `ARG` del Dockerfile.*
