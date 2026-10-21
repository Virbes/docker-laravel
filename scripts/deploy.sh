#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE="docker compose -f docker-compose.prod.yml"
IMAGE="sentient-support/app:latest"     # ⚠️ Debe coincidir con "image:" del compose

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