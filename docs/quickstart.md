# Uso diario de la plantilla Docker

Esta guía asume que la plantilla ya está hecha. El detalle de por qué cada archivo existe está en [guia_v2.md](./guia_v2.md). Aquí solo queda copiar esos archivos a un proyecto Laravel + Inertia (React TSX), cambiar los valores de ese proyecto y usar los comandos de todos los días.

**Stack que esta plantilla espera:** Laravel 12 o 13 · PHP 8.4 · Node 22 · Inertia + React TSX · Vite · MySQL o MariaDB **fuera** de Docker.

Trabaja siempre desde la raíz del proyecto (donde está `artisan`).

---

## 1. Traer los archivos

El repositorio de la plantilla guarda solo la pieza de Docker. El proyecto Laravel sigue siendo el suyo: clonas o descargas la plantilla en otra carpeta y copias los archivos a la raíz del proyecto.

Archivos que viajan con la plantilla:

```
Dockerfile
.dockerignore
docker-compose.yml
docker-compose.prod.yml
docker/php/php-common.ini
docker/php/opcache-prod.ini
docker/php/dev-entrypoint.sh
scripts/deploy.sh
```

`.gitattributes` del proyecto Laravel ya suele existir. No lo reemplaces. Comprueba que incluya esta línea, para que `dev-entrypoint.sh` no se convierta a CRLF en Windows:

```gitattributes
*.sh text eol=lf
```


### Descargar el ZIP
https://github.com/Virbes/docker-laravel.git

Descomprime el ZIP y usa las mismas rutas de `cp`, cambiando `~/plantilla-docker` por la carpeta descomprimida.

Si el proyecto ya tiene un `.dockerignore`, fusiona el de la plantilla con el existente en lugar de pisarlo. Lo importante es que sigan excluidos `.env`, `vendor/` y `node_modules/`.

---

## 2. Valores que cambias en cada proyecto

Sustituye `sentient-support` (el nombre de ejemplo de esta plantilla) por un slug corto del proyecto nuevo, en minúsculas y sin espacios. El mismo slug se repite en varios archivos: si uno queda con el nombre viejo, Compose mezcla contenedores o el deploy copia la imagen equivocada.

### Siempre

| Dónde | Qué dice la plantilla | Qué pones |
|---|---|---|
| `docker-compose.yml` → `name:` | `sentient-support` | Slug del proyecto. Define el nombre de los contenedores (`<slug>-app-1`). |
| `docker-compose.prod.yml` → `name:` | `sentient-support-prod` | `<slug>-prod`. Único en el servidor si conviven varios proyectos. |
| `docker-compose.prod.yml` → `image:` | `sentient-support/app:latest` | `<slug>/app:latest`. |
| `scripts/deploy.sh` → `IMAGE=` | `sentient-support/app:latest` | El mismo valor que `image:` de arriba, carácter por carácter. |
| `.env` → `APP_NAME` | — | Nombre visible de la app. |
| `.env` → `APP_URL` | — | `http://localhost:8000` en desarrollo. Si cambias `APP_PORT`, esta URL usa ese puerto. |
| `.env` → `APP_KEY` | vacío | La genera el comando de la sección 4. No la inventes. |
| `.env` → `DB_CONNECTION` | — | `mysql`, o `mariadb` si el servidor es MariaDB (XAMPP). |
| `.env` → `DB_HOST` | — | `host.docker.internal` en desarrollo (el MySQL de tu equipo, visto desde el contenedor). En producción, la IP o el hostname del servidor de BD. |
| `.env` → `DB_PORT` | — | `3306`, salvo que tu MySQL use otro. |
| `.env` → `DB_DATABASE` | — | Nombre de la base de este proyecto. |
| `.env` → `DB_USERNAME` | — | Usuario de esa base. |
| `.env` → `DB_PASSWORD` | — | Clave. Si contiene `$`, enciérrala en comillas simples: `DB_PASSWORD='ab$cd'`. |
| `.env` → `DOCKER_UID` | `1000` | El resultado de `id -u` en tu máquina. |
| `.env` → `DOCKER_GID` | `1000` | El resultado de `id -g` en tu máquina. |

El `.env` no va en Git. Créalo desde el ejemplo si aún no existe:

```bash
cp .env.example .env
id -u
id -g
```

Escribe esos dos números en `DOCKER_UID` y `DOCKER_GID`. En Linux o WSL también puedes dejar que `sed` los ponga:

```bash
sed -i "s/^DOCKER_UID=.*/DOCKER_UID=$(id -u)/; s/^DOCKER_GID=.*/DOCKER_GID=$(id -g)/" .env
```

`DB_HOST=127.0.0.1` dentro del contenedor apunta al propio contenedor. Para el MySQL de tu equipo el valor es `host.docker.internal`.

Estos tres tienen que ser idénticos:

```yaml
# docker-compose.prod.yml
image: mi-proyecto/app:latest
```

```bash
# scripts/deploy.sh
IMAGE="mi-proyecto/app:latest"
```

### Solo si el puerto ya está ocupado

| Dónde | Valor de la plantilla | Cuándo cambiarlo |
|---|---|---|
| `.env` → `APP_PORT` | `8000` | Otro proyecto ya usa el 8000 en tu máquina. El contenedor sigue escuchando en el 8000 interno; Compose publica `APP_PORT` hacia afuera. Actualiza también `APP_URL`. |
| `.env` → `VITE_PORT` | `5173` | Otro proyecto ya usa el 5173. Cámbialo junto con `server.port` en `vite.config.ts`. El mapeo del compose es `"${VITE_PORT}:5173"`, así que si Vite escucha en otro puerto interno, el lado derecho de ese mapeo tiene que ser el mismo número. |
| `.env` de producción → `FPM_PORT` | `9001` | Cada proyecto del mismo servidor lleva un puerto distinto (`9001`, `9002`, …). Nginx hace `fastcgi_pass 127.0.0.1:<ese puerto>`. |

### Casi nunca

| Dónde | Valor | Cuándo |
|---|---|---|
| `Dockerfile` → `ARG PHP_VERSION` | `8.4` | El proyecto pide otra versión de PHP. Hay que reconstruir la imagen. |
| `Dockerfile` → `ARG NODE_VERSION` | `22` | El proyecto pide otra versión de Node. Laravel 13.25+ con `artisan dev` necesita Node 22.13 o superior. |
| `Dockerfile` → `install-php-extensions` | `pdo_mysql mbstring intl zip gd bcmath pcntl exif opcache` | Una librería PHP nueva exige una extensión que no está en la lista (por ejemplo `redis` o `soap`). Hay que reconstruir la imagen. |
| `docker/php/php-common.ini` → `date.timezone` | `America/Mexico_City` | El proyecto vive en otra zona horaria. Hay que reconstruir la imagen. |

El resto del `Dockerfile`, el entrypoint y los `.ini` se quedan igual de un proyecto a otro.

---

## 3. Dos ajustes en el código de la app

No vienen en el ZIP de Docker. Van en el proyecto Laravel.

### Vite

En `vite.config.ts`, el bloque `server` deja a Vite visible desde el navegador:

```ts
server: {
    host: '0.0.0.0',
    port: 5173,
    strictPort: true,
    hmr: {
        host: 'localhost',
    },
},
```

`host: '0.0.0.0'` es dentro del contenedor. `hmr.host: 'localhost'` es la dirección que usa tu navegador.

### Laravel 13.16 a 13.24

En esas versiones, `php artisan dev` arranca el servidor con `--host=localhost` y no lee `SERVER_HOST`. El contenedor queda en marcha y `http://localhost:8000` responde vacío.

En `app/Providers/AppServiceProvider.php`:

```php
use Illuminate\Foundation\DevCommands;

protected function configureHost(): void
{
    if ($this->app->environment('local')) {
        DevCommands::artisan('serve --host=0.0.0.0 --port=8000', 'server');
    }
}
```

Llama a `configureHost()` desde `boot()`. El puerto de esa línea es el **interno** del contenedor y se queda en `8000`, aunque `APP_PORT` del `.env` sea otro.

A partir de Laravel 13.25 el framework ya respeta `SERVER_HOST` y este método sobra. Para saber cuál tienes:

```bash
docker compose run --rm app php artisan --version
```

---

## 4. Construir la imagen la primera vez

MySQL de tu equipo tiene que estar encendido y la base del `.env` ya creada.

```bash
docker compose build
docker compose run --rm app php artisan key:generate
docker compose run --rm app php artisan migrate
docker compose up
```

Qué hace cada uno:

1. `build` crea la imagen de desarrollo (PHP, extensiones, Node, Composer). La primera vez tarda varios minutos.
2. `key:generate` escribe `APP_KEY` en el `.env`.
3. `migrate` crea las tablas. La base de datos es la de tu equipo, no un contenedor.
4. `up` arranca el contenedor en primer plano. La primera vez, el entrypoint ejecuta `composer install` y `npm install` si faltan `vendor/` o `node_modules/`.

Abre <http://localhost:8000>. En el log tiene que aparecer el servidor en `0.0.0.0:8000` y Vite en el puerto 5173. `Ctrl+C` detiene esa sesión.

Para dejarlo en segundo plano:

```bash
docker compose up -d
docker compose logs -f --tail=100
```

---

## 5. Día a día

El código (PHP, TSX, CSS) está montado desde tu carpeta. Guardar un archivo alcanza: no hace falta reconstruir la imagen ni reinstalar nada.

| Qué quieres | Comando |
|---|---|
| Arrancar lo que ya estaba creado | `docker compose start` |
| Parar sin borrar el contenedor | `docker compose stop` |
| Ver si está arriba | `docker compose ps` |
| Ver los logs | `docker compose logs -f --tail=100` |
| Crear el contenedor la primera vez, o recrearlo tras editar el compose | `docker compose up -d` |
| Parar y borrar el contenedor (la base de datos no se toca) | `docker compose down` |

`start` y `stop` reutilizan el contenedor que `up` ya creó. Si acabas de copiar la plantilla, el primer comando es `up`, no `start`. Si cambias puertos en el compose o en el `.env` de Docker (`APP_PORT`, `VITE_PORT`), `start` no los aplica: usa `docker compose up -d` para que Compose recree el contenedor.

`docker compose down` borra el contenedor, no la imagen ni tu MySQL. Los archivos de `storage/` siguen en tu carpeta.

---

## 6. Artisan, npm y una shell

Con el contenedor en marcha (`start` o `up`), entra con `docker compose exec`. No hace falta recordar el nombre del contenedor:

```bash
docker compose exec app php artisan migrate
docker compose exec app php artisan test
docker compose exec app php artisan tinker
docker compose exec app npm run lint
docker compose exec app npx tsc --noEmit
docker compose exec app bash
```

El equivalente con `docker exec` usa el nombre que muestra `docker compose ps`. Con `name: sentient-support` el contenedor se llama `sentient-support-app-1`:

```bash
docker exec -it sentient-support-app-1 php artisan migrate
docker exec -it sentient-support-app-1 npm run lint
```

`-it` hace falta para comandos interactivos (`tinker`, `bash`). Para un comando que solo imprime y termina, `-it` se puede omitir.

Si el contenedor está parado, `exec` no tiene dónde entrar. Usa `run`, que levanta un contenedor temporal y lo borra al salir:

```bash
docker compose run --rm app php artisan migrate
docker compose run --rm app npm run lint
```

Instala dependencias de PHP y de Node **dentro** del contenedor. Un `npm install` hecho en Windows deja binarios (`esbuild`, `rollup`) que dentro de la imagen Alpine no arrancan.

---

## 7. Instalar una librería

El contenedor tiene que estar arriba (`docker compose start` o `up -d`). Los archivos quedan en tu carpeta (`vendor/`, `composer.lock`, `node_modules/`, `package-lock.json`) porque el proyecto está montado ahí.

### Laravel (PHP)

```bash
docker compose exec app composer require laravel/sanctum
```

Solo para desarrollo (tests, Pint, generadores):

```bash
docker compose exec app composer require --dev laravel/pint
```

Quitar un paquete:

```bash
docker compose exec app composer remove laravel/sanctum
```

Si el paquete trae migraciones:

```bash
docker compose exec app php artisan migrate
```

### React

```bash
docker compose exec app npm install lucide-react
```

Dependencia solo de desarrollo (compilador, plugins de Vite, ESLint):

```bash
docker compose exec app npm install -D eslint
```

Quitar un paquete:

```bash
docker compose exec app npm uninstall lucide-react
```

Vite suele recargar solo. Si el import nuevo no resuelve, reinicia el contenedor: `docker compose restart`.

### TypeScript

Los tipos que publica el propio paquete llegan con el `npm install` de arriba. Cuando el paquete no trae tipos:

```bash
docker compose exec app npm install -D @types/node
```

Comprobar el proyecto sin emitir archivos:

```bash
docker compose exec app npx tsc --noEmit
```

Una extensión de PHP nueva (la que se declara en `php.ini` o en `install-php-extensions`, no un paquete de Composer) sí obliga a editar el `Dockerfile` y a reconstruir la imagen. Un `composer require` normal no.

---

## 8. Borrar la imagen y reconstruirla desde cero

Hazlo cuando cambies el `Dockerfile`, los `.ini`, el entrypoint o `DOCKER_UID` / `DOCKER_GID`. El código de la app no necesita esto.

Parar y borrar contenedor e imagen de este proyecto:

```bash
docker compose down --rmi local
```

Reconstruir sin reutilizar capas viejas y volver a levantar:

```bash
docker compose build --no-cache
docker compose up -d
```

`vendor/` y `node_modules/` viven en tu carpeta, no dentro de la imagen de desarrollo. Borrar la imagen no los reinstala. Para reinstalar dependencias desde cero:

```bash
docker compose down
rm -rf vendor node_modules
docker compose build --no-cache
docker compose up
```

El entrypoint vuelve a ejecutar `composer install` y `npm install` porque esas carpetas ya no están.

Liberar la caché de builds de Docker (afecta a todos los proyectos de la máquina):

```bash
docker builder prune -f
```

---

## 9. Producción, en corto

El día a día de arriba es el compose de desarrollo (`docker-compose.yml`). En el servidor se usa el otro archivo y el script:

```bash
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs --tail=100 app
docker compose -f docker-compose.prod.yml exec app php artisan migrate --force
./scripts/deploy.sh
```

Antes del primer `./scripts/deploy.sh` tienen que coincidir el slug de la sección 2, el `.env` de producción (`APP_ENV=production`, `APP_DEBUG=false`, `FPM_PORT`, `DB_HOST` del servidor de BD) y el vhost de Nginx. Ese montaje está en los pasos 11 a 13 de [guia_v2.md](./guia_v2.md).

`docker compose down -v` y borrar `storage/` en el servidor se llevan los archivos subidos por los usuarios. La base de datos está fuera de Docker, pero `storage/app` no.
