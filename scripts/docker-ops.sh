#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

COMPOSE_CMD=()

usage() {
  cat <<'EOF'
Usage: ./scripts/docker-ops.sh <command> [args...]

Commands:
  ps                  Show running compose services
  ps-a                Show all compose services (including stopped)
  up [services...]    Build and start all or selected services in detached mode
  start [services...] Start stopped services (all if omitted)
  stop [services...]  Stop running services (all if omitted)
  restart [services...] Restart services (all if omitted)
  down                Stop and remove containers/networks
  down-v              Stop and remove containers/networks/volumes
  logs [service]      Follow logs (all services if omitted)
  logs-tail [service] [lines]
                      Show recent logs (default lines=200)
  exec <service> <cmd...>
                      Run a one-off command in a running service container
  help                Show this help

Examples:
  ./scripts/docker-ops.sh up
  ./scripts/docker-ops.sh up mekeeli-api mekeeli-ui
  ./scripts/docker-ops.sh logs mekeeli-api
  ./scripts/docker-ops.sh logs-tail ollama 300
  ./scripts/docker-ops.sh stop mekeeli-ui
  ./scripts/docker-ops.sh restart mekeeli-api
  ./scripts/docker-ops.sh exec mekeeli-api uv run alembic upgrade head
EOF
}

ensure_compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return 0
  fi

  printf '[docker-ops] Docker Compose is not available.\n' >&2
  exit 1
}

main() {
  ensure_compose

  local command="${1:-help}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$command" in
    ps)
      "${COMPOSE_CMD[@]}" ps
      ;;
    ps-a)
      "${COMPOSE_CMD[@]}" ps -a
      ;;
    up)
      "${COMPOSE_CMD[@]}" up -d --build "$@"
      ;;
    start)
      if [[ $# -gt 0 ]]; then
        "${COMPOSE_CMD[@]}" start "$@"
      else
        "${COMPOSE_CMD[@]}" start
      fi
      ;;
    stop)
      if [[ $# -gt 0 ]]; then
        "${COMPOSE_CMD[@]}" stop "$@"
      else
        "${COMPOSE_CMD[@]}" stop
      fi
      ;;
    restart)
      if [[ $# -gt 0 ]]; then
        "${COMPOSE_CMD[@]}" restart "$@"
      else
        "${COMPOSE_CMD[@]}" restart
      fi
      ;;
    down)
      "${COMPOSE_CMD[@]}" down
      ;;
    down-v)
      "${COMPOSE_CMD[@]}" down -v
      ;;
    logs)
      if [[ $# -gt 0 ]]; then
        "${COMPOSE_CMD[@]}" logs -f "$1"
      else
        "${COMPOSE_CMD[@]}" logs -f
      fi
      ;;
    logs-tail)
      local service="${1:-}"
      local lines="${2:-200}"
      if [[ -n "$service" ]]; then
        "${COMPOSE_CMD[@]}" logs --tail="$lines" "$service"
      else
        "${COMPOSE_CMD[@]}" logs --tail="$lines"
      fi
      ;;
    exec)
      if [[ $# -lt 2 ]]; then
        printf '[docker-ops] Usage: exec <service> <cmd...>\n' >&2
        exit 1
      fi
      local service="$1"
      shift
      "${COMPOSE_CMD[@]}" exec "$service" "$@"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      printf '[docker-ops] Unknown command: %s\n' "$command" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
