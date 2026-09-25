#!/usr/bin/env bash
# Install or update FantikPay on an Ubuntu 22.04/24.04 server (Yandex Cloud VM, etc.).
#
#   sudo bash deploy/install.sh                 # domain: <ip>.sslip.io (free HTTPS without a domain)
#   sudo FP_DOMAIN=fantikpay.ru bash deploy/install.sh
#
# Safe to run again: pulls the latest code of the current branch and restarts the stack.
# Secrets are generated once into .env next to docker-compose.yml and never overwritten.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

# --- Docker ---------------------------------------------------------------------------
# An existing Docker is left as it is: no config changes, no restart of running containers.
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  if command -v docker >/dev/null; then
    echo "Docker is installed but 'docker compose' is missing. Install the compose plugin and rerun."
    exit 1
  fi
  log "Installing Docker"
  apt-get update -qq
  apt-get install -y -qq docker.io >/dev/null
  apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 \
    || apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 \
    || { curl -fsSL https://get.docker.com | sh; }
  # Docker Hub is not always reachable from Russia: pull through a mirror first.
  if [ ! -f /etc/docker/daemon.json ]; then
    echo '{"registry-mirrors": ["https://mirror.gcr.io"]}' > /etc/docker/daemon.json
  fi
  systemctl enable docker >/dev/null
  systemctl restart docker
fi

# Ports 80/443 taken by another service (not our own Caddy from a previous run): stop.
if ss -tlnH '( sport = :80 or sport = :443 )' | grep -q . \
   && [ -z "$(docker compose ps -q caddy 2>/dev/null)" ]; then
  echo "Ports 80/443 are already used by another service on this server:"
  ss -tlnp '( sport = :80 or sport = :443 )'
  echo "Stopping here so nothing breaks. See docs/deploy-yandex-cloud.md, 'Сервер уже занят'."
  exit 1
fi

# --- Small VMs need swap to build the image --------------------------------------------
if [ "$(free -m | awk '/Mem:/ {print $2}')" -lt 2000 ] && ! swapon --show | grep -q .; then
  log "Adding 2 GB swap"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q /swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- Code -------------------------------------------------------------------------------
if [ -d .git ]; then
  log "Updating code ($(git rev-parse --abbrev-ref HEAD))"
  sudo -u "$(stat -c %U .git)" git pull --ff-only || echo "git pull failed — deploying the current checkout"
fi

# --- Settings ---------------------------------------------------------------------------
if [ ! -f .env ]; then
  IP=$(curl -fsS https://ifconfig.me || curl -fsS https://api.ipify.org)
  DOMAIN=${FP_DOMAIN:-${IP//./-}.sslip.io}
  log "Creating .env for $DOMAIN"
  cat > .env <<ENV
POSTGRES_PASSWORD=$(openssl rand -hex 24)
FP_ENV=prod
FP_JWT_SECRET=$(openssl rand -hex 32)
FP_DOMAIN=$DOMAIN
FP_PUBLIC_BASE_URL=https://fantikpay.ru
ENV
  chmod 600 .env
elif [ -n "${FP_DOMAIN:-}" ]; then
  sed -i "s/^FP_DOMAIN=.*/FP_DOMAIN=$FP_DOMAIN/" .env
fi
DOMAIN=$(grep '^FP_DOMAIN=' .env | cut -d= -f2)
mkdir -p backups

# --- Start ------------------------------------------------------------------------------
log "Building and starting (first time takes a few minutes)"
docker compose up -d --build --remove-orphans

log "Waiting for https://$DOMAIN/health"
for _ in $(seq 1 60); do
  if curl -fsS "https://$DOMAIN/health" >/dev/null 2>&1; then
    log "FantikPay is running: https://$DOMAIN"
    echo "App:      flutter run --dart-define=API_URL=https://$DOMAIN"
    echo "Demo:     sudo docker compose -f $ROOT/docker-compose.yml exec api python -m app.cli seed-demo"
    echo "Logs:     sudo docker compose -f $ROOT/docker-compose.yml logs -f api"
    echo "Backups:  $ROOT/backups (daily)"
    exit 0
  fi
  sleep 5
done
echo "API did not answer over HTTPS. Check that ports 80 and 443 are open in the VM security group,"
echo "then look at: docker compose logs caddy api"
exit 1
