#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
COMPOSE_CMD=()
DOCKER_CMD=(docker)
OS_ID=""
OS_LIKE=""
ASSUME_YES=false
SYNC_REPOS=true
PULL_REPOS=false
SKIP_MODEL_BOOTSTRAP=false

usage() {
  cat <<'EOF'
Usage: ./setup.sh [options]

Options:
  -y, --yes         Non-interactive mode. Auto-approve install actions.
      --no-sync     Skip syncing git submodules.
      --pull-repos  Pull latest remote commits for submodules (tracks branch).
      --skip-model-bootstrap  Skip waiting for Ollama model bootstrap completion.
  -h, --help        Show this help text.
EOF
}

log() {
  printf '[setup] %s\n' "$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --no-sync)
      SYNC_REPOS=false
      shift
      ;;
    --pull-repos)
      PULL_REPOS=true
      shift
      ;;
    --skip-model-bootstrap)
      SKIP_MODEL_BOOTSTRAP=true
      shift
      ;;
    *)
      log "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

wait_for_service_healthy() {
  local service="$1"
  local attempts="$2"
  local delay="$3"

  for _ in $(seq 1 "$attempts"); do
    local container_id
    container_id="$("${COMPOSE_CMD[@]}" ps -q "$service" 2>/dev/null || true)"
    if [[ -z "$container_id" ]]; then
      sleep "$delay"
      continue
    fi

    local health_status
    health_status="$("${DOCKER_CMD[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || true)"
    if [[ "$health_status" == "healthy" ]]; then
      log "$service is healthy."
      return 0
    fi

    local state_status
    state_status="$("${DOCKER_CMD[@]}" inspect -f '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
    if [[ "$state_status" == "exited" || "$state_status" == "dead" ]]; then
      log "$service stopped unexpectedly (status: $state_status)."
      "${COMPOSE_CMD[@]}" logs --tail=100 "$service" || true
      return 1
    fi

    sleep "$delay"
  done

  log "$service did not become healthy in time."
  "${COMPOSE_CMD[@]}" logs --tail=100 "$service" || true
  return 1
}

wait_for_ollama_models() {
  local timeout_seconds="${OLLAMA_BOOTSTRAP_TIMEOUT_SECONDS:-3600}"
  local verbose_logs="${OLLAMA_BOOTSTRAP_VERBOSE_LOGS:-true}"
  local models_raw="${OLLAMA_REQUIRED_MODELS:-qwen3-vl:4b,embeddinggemma}"
  local delay=5
  local elapsed=0
  local log_pid=""

  models_raw="${models_raw//,/ }"

  stop_ollama_bootstrap_log_stream() {
    if [[ -n "$log_pid" ]] && kill -0 "$log_pid" >/dev/null 2>&1; then
      kill "$log_pid" >/dev/null 2>&1 || true
      wait "$log_pid" 2>/dev/null || true
    fi
  }

  if [[ "$verbose_logs" == "true" ]]; then
    log "Streaming verbose ollama logs..."
    "${COMPOSE_CMD[@]}" logs -f --tail=200 ollama &
    log_pid=$!
  fi

  while [[ "$elapsed" -lt "$timeout_seconds" ]]; do
    local list_output=""
    if list_output="$("${COMPOSE_CMD[@]}" exec -T ollama ollama list 2>/dev/null)"; then
      local missing_models=()
      local model
      for model in $models_raw; do
        if ! printf '%s\n' "$list_output" | grep -Fq "$model"; then
          missing_models+=("$model")
        fi
      done

      if [[ "${#missing_models[@]}" -eq 0 ]]; then
        stop_ollama_bootstrap_log_stream
        log "Ollama model bootstrap completed (${models_raw})."
        return 0
      fi
    fi

    if (( elapsed % 30 == 0 )); then
      log "Waiting for Ollama models (${models_raw})... (${elapsed}s elapsed)"
    fi
    sleep "$delay"
    elapsed=$((elapsed + delay))
  done

  stop_ollama_bootstrap_log_stream
  log "Timed out waiting for Ollama models after ${timeout_seconds}s."
  "${COMPOSE_CMD[@]}" logs --tail=200 ollama || true
  return 1
}

ensure_repo_modules() {
  if [[ "$SYNC_REPOS" != "true" ]]; then
    return 0
  fi

  if [[ ! -f ".gitmodules" ]]; then
    return 0
  fi

  if ! have_cmd git; then
    log "git is required to sync mekeeli-api/mekeeli-ui but is not installed."
    exit 1
  fi

  log "Syncing repository modules (mekeeli-api, mekeeli-ui)..."
  git submodule sync --recursive

  if [[ "$PULL_REPOS" == "true" ]]; then
    log "Pulling latest remote commits for submodules..."
    git submodule update --init --recursive --remote --merge
  else
    git submodule update --init --recursive
  fi
}

load_os_release() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  fi
}

is_debian_like_linux() {
  [[ "$OSTYPE" == "linux-gnu"* ]] && [[ "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" || "$OS_LIKE" == *"debian"* ]]
}

confirm_or_exit() {
  local prompt="$1"
  if [[ "$ASSUME_YES" == "true" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    log "$prompt"
    log "Non-interactive shell detected. Re-run with --yes to auto-approve."
    exit 1
  fi

  printf '[setup] %s [y/N]: ' "$prompt"
  read -r answer
  case "$answer" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      log "Aborted by user."
      exit 1
      ;;
  esac
}

as_root() {
  if [[ "${EUID:-0}" -eq 0 ]]; then
    "$@"
  elif have_cmd sudo; then
    if [[ "$ASSUME_YES" == "true" ]]; then
      sudo -n "$@" || sudo "$@"
    else
      sudo "$@"
    fi
  else
    log "This step requires elevated privileges but sudo is not available."
    exit 1
  fi
}

ensure_writable_dir() {
  local target="$1"
  local mode="${2:-0777}"

  if mkdir -p "$target" >/dev/null 2>&1; then
    chmod -R "$mode" "$target" >/dev/null 2>&1 || true
    return 0
  fi

  log "Permission issue creating $target. Attempting elevated fix..."
  as_root mkdir -p "$target"
  as_root chmod -R "$mode" "$target"

  local owner="${SUDO_USER:-${USER:-}}"
  if [[ -n "$owner" ]]; then
    as_root chown -R "$owner":"$owner" "$target" || true
  fi
}

install_with_brew() {
  local package="$1"
  if ! have_cmd brew; then
    return 1
  fi
  brew install "$package"
}

install_cask_with_brew() {
  local package="$1"
  if ! have_cmd brew; then
    return 1
  fi
  brew install --cask "$package"
}

install_docker_linux_debian() {
  log "Installing Docker for Debian/Ubuntu..."
  as_root apt-get update
  as_root apt-get install -y docker.io
  as_root apt-get install -y docker-compose-plugin || true
  as_root systemctl enable --now docker || as_root service docker start || true
  if [[ "${EUID:-0}" -ne 0 ]] && id -nG "$USER" | grep -qvw docker; then
    as_root usermod -aG docker "$USER" || true
  fi
}

ensure_docker_cli() {
  if have_cmd docker; then
    return 0
  fi

  log "Docker CLI not found. Attempting installation..."
  confirm_or_exit "Docker is missing and setup will install it."
  if [[ "$OSTYPE" == "darwin"* ]]; then
    install_cask_with_brew docker || {
      log "Failed to install Docker Desktop automatically."
      log "Install manually: https://www.docker.com/products/docker-desktop/"
      exit 1
    }
    return 0
  fi

  if is_debian_like_linux; then
    install_docker_linux_debian
    if have_cmd docker; then
      return 0
    fi
  fi

  log "Automatic Docker install is not configured for this OS."
  log "Install Docker manually, then re-run ./setup.sh"
  exit 1
}

install_compose_linux_debian() {
  log "Installing Docker Compose for Debian/Ubuntu..."
  as_root apt-get update
  as_root apt-get install -y docker-compose-plugin || true
  as_root apt-get install -y docker-compose || true
}

start_docker_if_needed() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    if ! docker info >/dev/null 2>&1; then
      log "Starting Docker Desktop..."
      open -a Docker || true
    fi
  elif is_debian_like_linux; then
    as_root systemctl start docker || as_root service docker start || true
  fi

  log "Waiting for Docker daemon..."
  for _ in $(seq 1 90); do
    if docker info >/dev/null 2>&1; then
      DOCKER_CMD=(docker)
      log "Docker is ready."
      return 0
    fi
    if have_cmd sudo && sudo docker info >/dev/null 2>&1; then
      DOCKER_CMD=(sudo docker)
      log "Docker is ready (using sudo)."
      return 0
    fi
    sleep 2
  done

  log "Docker daemon did not become ready in time."
  if is_debian_like_linux; then
    log "If Docker was just installed, you may need to re-login for docker group changes."
  else
    log "Ensure Docker Desktop is running, then re-run ./setup.sh"
  fi
  exit 1
}

ensure_env_file() {
  local target="$1"
  local fallback="$2"
  if [[ -f "$target" ]]; then
    return 0
  fi
  if [[ -f "$fallback" ]]; then
    cp "$fallback" "$target"
    log "Created $target from $fallback"
    return 0
  fi
  log "Missing required env file: $target (no fallback $fallback found)"
  exit 1
}

ensure_docker_compose() {
  if "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("${DOCKER_CMD[@]}" compose)
    return 0
  fi
  if have_cmd docker-compose; then
    COMPOSE_CMD=(docker-compose)
    return 0
  fi
  if have_cmd sudo && sudo docker-compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(sudo docker-compose)
    return 0
  fi

  log "Docker Compose not found. Attempting installation..."
  confirm_or_exit "Docker Compose is missing and setup will install it."
  if [[ "$OSTYPE" == "darwin"* ]]; then
    install_with_brew docker-compose || {
      log "Failed to install docker-compose."
      log "Install Docker Desktop or docker-compose plugin, then re-run ./setup.sh"
      exit 1
    }
  elif is_debian_like_linux; then
    install_compose_linux_debian
  else
    log "Automatic Compose install is not configured for this OS."
    log "Install Docker Compose plugin manually, then re-run ./setup.sh"
    exit 1
  fi

  if "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("${DOCKER_CMD[@]}" compose)
    return 0
  fi
  if have_cmd docker-compose; then
    COMPOSE_CMD=(docker-compose)
    return 0
  fi
  if have_cmd sudo && sudo docker-compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(sudo docker-compose)
    return 0
  fi

  log "Docker Compose still unavailable after installation attempt."
  exit 1
}

wait_for_http() {
  local name="$1"
  local url="$2"
  local attempts="$3"
  local delay="$4"

  for _ in $(seq 1 "$attempts"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      log "$name is reachable at $url"
      return 0
    fi
    sleep "$delay"
  done

  log "$name did not become reachable at $url"
  return 1
}

load_os_release
ensure_repo_modules
ensure_docker_cli
start_docker_if_needed
ensure_docker_compose

ensure_env_file ".env.local" ".env.template"
ensure_env_file ".env" ".env.local"
ensure_env_file "mekeeli-api/.env" "mekeeli-api/.env.template"
ensure_env_file "mekeeli-api/.env.local" "mekeeli-api/.env.template"

# Pre-create writable shared data paths under root volumes.
ensure_writable_dir "volumes/mekeeli_data"
ensure_writable_dir "volumes/uploads/files"
ensure_writable_dir "volumes/uploads/attachments"

log "Starting core services (db, ollama)..."
"${COMPOSE_CMD[@]}" up -d --build db ollama

wait_for_service_healthy "db" 120 2
wait_for_service_healthy "ollama" 180 2

if [[ "$SKIP_MODEL_BOOTSTRAP" == "true" ]]; then
  log "Skipped waiting for Ollama model bootstrap."
  log "Model pulls continue in the ollama service logs."
else
  log "Waiting for Ollama model bootstrap to complete before starting app services..."
  wait_for_ollama_models
fi

log "Starting application services (mekeeli-api, mekeeli-ui, mekeeli-backup)..."
"${COMPOSE_CMD[@]}" up -d --build mekeeli-api mekeeli-ui mekeeli-backup

if ! have_cmd curl; then
  log "curl not found; skipping HTTP readiness checks."
else
  wait_for_http "Mekeeli API" "http://localhost:8000/health" 90 2 || true
  wait_for_http "Mekeeli UI" "http://localhost:3000" 90 2 || true
fi

log "Setup complete."
log "Open the platform: http://localhost:3000"
