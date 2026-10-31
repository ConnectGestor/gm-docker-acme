#!/bin/bash
# Atualiza a nuvem do GoManager na VPS: baixa o deploy e a imagem nova do ghcr.io.
# Não faz build. Na pasta em que está o credentials.env:
#   curl -sSL https://raw.githubusercontent.com/ConnectGestor/gm-docker-acme/main/update.sh | bash
set -euo pipefail

REPO_URL="${GM_DEPLOY_REPO:-https://github.com/ConnectGestor/gm-docker-acme.git}"
REPO_RAMO="${GM_DEPLOY_BRANCH:-main}"
REPO_DIR="${GM_DEPLOY_DIR:-$HOME/gm-docker-acme}"
DIR="${APP_DIR:-$HOME/appmobile-nuvem}"

carregar_credenciais() {
  local f
  for f in ./credentials.env "$HOME/credentials.env" /root/credentials.env; do
    if [ -f "$f" ]; then
      set -a
      # shellcheck disable=SC1090
      . "$f"
      set +a
      return 0
    fi
  done
  return 1
}

login_registro() {
  carregar_credenciais || true
  if [ -z "${DOCKER_REGISTRY:-}" ] || [ -z "${DOCKER_USER:-}" ] || [ -z "${DOCKER_PASSWORD:-}" ]; then
    echo "Não achei DOCKER_REGISTRY, DOCKER_USER e DOCKER_PASSWORD. Coloque o credentials.env na pasta atual, como no ConnectGestor."
    exit 1
  fi
  echo "$DOCKER_PASSWORD" | docker login "$DOCKER_REGISTRY" --username "$DOCKER_USER" --password-stdin
}

# Deixa REPO_DIR igual ao ramo publicado. Ninguém edita essa pasta na VPS.
baixar_deploy() {
  if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" fetch --quiet --depth 1 origin "$REPO_RAMO"
    git -C "$REPO_DIR" reset --quiet --hard FETCH_HEAD
  else
    git clone --quiet --depth 1 --branch "$REPO_RAMO" "$REPO_URL" "$REPO_DIR"
  fi
}

if [ ! -f "$DIR/docker-compose.yml" ]; then
  echo "Instalação não encontrada em $DIR. Rode o setup.sh antes."
  exit 1
fi

# Confere a credencial antes de mexer em qualquer arquivo da instalação.
login_registro

baixar_deploy
cp "$REPO_DIR/docker-compose.yml" "$DIR/docker-compose.yml"
cp "$REPO_DIR/Caddyfile" "$DIR/Caddyfile"

cd "$DIR"
docker compose pull
docker compose up -d
# O stdin fica fechado: no curl | bash ele é o próprio script, e o exec o engoliria.
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile </dev/null >/dev/null 2>&1 || true
docker image prune -f >/dev/null || true
echo "Atualização concluída."
