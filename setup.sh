#!/bin/bash
# Instala ou atualiza a nuvem do GoManager na VPS.
# Não faz build: baixa a imagem que o GitHub Actions publica em
# ghcr.io/connectgestor/gomanager-app. Na pasta em que está o credentials.env
# (DOCKER_REGISTRY, DOCKER_USER e DOCKER_PASSWORD):
#   curl -sSL https://raw.githubusercontent.com/ConnectGestor/gm-docker-acme/main/setup.sh | bash -s nuvem.seudominio.com email@seudominio.com
# Numa VPS que já tem ~/appmobile-nuvem, o mesmo comando só troca o domínio (DOMAIN
# no .env), atualiza o compose e o Caddyfile e baixa a imagem nova. Não recria o
# .env e não apaga o Postgres dos volumes.
set -euo pipefail

DOMINIO="${1:-}"
EMAIL="${2:-}"
if [ -z "$DOMINIO" ] || [ -z "$EMAIL" ]; then
  echo "Uso: setup.sh nuvem.seudominio.com email@seudominio.com"
  exit 1
fi

REPO_URL="${GM_DEPLOY_REPO:-https://github.com/ConnectGestor/gm-docker-acme.git}"
REPO_RAMO="${GM_DEPLOY_BRANCH:-main}"
REPO_DIR="${GM_DEPLOY_DIR:-$HOME/gm-docker-acme}"
DIR="${APP_DIR:-$HOME/appmobile-nuvem}"
IMAGEM_PADRAO="ghcr.io/connectgestor/gomanager-app:main"

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

atualizar_chave_env() {
  local arquivo="$1"
  local chave="$2"
  local valor="$3"
  if grep -q "^${chave}=" "$arquivo"; then
    sed -i "s|^${chave}=.*|${chave}=${valor}|" "$arquivo"
  else
    printf '%s=%s\n' "$chave" "$valor" >> "$arquivo"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "Instalando o Docker..."
  curl -fsSL https://get.docker.com | sh
fi
if ! command -v git >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y git ca-certificates
fi

# Confere a credencial antes de mexer em qualquer arquivo da instalação.
login_registro

mkdir -p "$DIR"

EXISTENTE=0
if [ -f "$DIR/.env" ] && [ -f "$DIR/docker-compose.yml" ]; then
  EXISTENTE=1
fi

baixar_deploy

if [ "$EXISTENTE" -eq 1 ]; then
  DOMINIO_ANTIGO="$(grep '^DOMAIN=' "$DIR/.env" | cut -d= -f2- || true)"
  echo "Instalação existente em $DIR."
  if [ -n "$DOMINIO_ANTIGO" ] && [ "$DOMINIO_ANTIGO" != "$DOMINIO" ]; then
    echo "Trocando o domínio de $DOMINIO_ANTIGO para $DOMINIO (o banco de dados não é apagado)."
  else
    echo "Atualizando o compose e baixando a imagem nova (o banco de dados não é apagado)."
  fi
  atualizar_chave_env "$DIR/.env" DOMAIN "$DOMINIO"
else
  cat > "$DIR/.env" <<EOF
DOMAIN=$DOMINIO
EMAIL=$EMAIL
POSTGRES_PASSWORD=$(openssl rand -hex 24)
SEGREDO=$(openssl rand -hex 32)
ADMIN_USUARIO=$EMAIL
TOKEN_EMPRESA=
EMPRESA_NOME=
APP_IMAGE=$IMAGEM_PADRAO
EOF
  chmod 600 "$DIR/.env"
fi

cp "$REPO_DIR/docker-compose.yml" "$DIR/docker-compose.yml"
cp "$REPO_DIR/Caddyfile" "$DIR/Caddyfile"
cp "$REPO_DIR/update.sh" "$DIR/update.sh"
chmod +x "$DIR/update.sh"

cd "$DIR"
docker compose pull
docker compose up -d
if [ "$EXISTENTE" -eq 1 ]; then
  # O stdin fica fechado: no curl | bash ele é o próprio script, e o exec o engoliria.
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile </dev/null >/dev/null 2>&1 || true
fi
docker image prune -f >/dev/null || true

echo
echo "Nuvem no ar: https://$DOMINIO/admin"
if [ "$EXISTENTE" -eq 0 ]; then
  echo "Login: $(grep '^ADMIN_USUARIO=' .env | cut -d= -f2-)"
  echo "Senha inicial: está na documentação do GoManager. Troque-a no perfil no primeiro acesso."
  echo "Cadastre cada empresa nessa página. O token gerado vai no computador da loja."
else
  echo "Conta da instalação e dados das empresas mantidos. Só o endereço HTTPS mudou se você alterou o domínio."
fi
