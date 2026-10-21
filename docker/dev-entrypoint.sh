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