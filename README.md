# Mekeeli

Local-first AI workspace with:
- `mekeeli-ui` (React/Vite frontend, user entrypoint)
- `mekeeli-api` (FastAPI backend + API)
- `db` (Postgres)
- `ollama` + `ollama-init` (local model runtime + model bootstrap)

Default local entrypoint for users is:
- `http://localhost:3000`

## Quick start (recommended)

From repo root:

```bash
./setup.sh
```

For non-interactive environments (CI/provisioning):

```bash
./setup.sh --yes
```

`setup.sh` will:
- check/install required tools (`docker`, `docker compose`) on macOS and Debian/Ubuntu
- start Docker if needed
- create missing env files from templates
- build and start the stack with Docker Compose
- use containerized `uv` inside the API image (host `uv` not required)
- pull default Ollama models:
  - `qwen2.5:7b-instruct`
  - `qwen2.5vl:7b`
  - `bge-m3`

## What runs

Current Compose services:
- `db` (Postgres 15)
- `ollama` (local model server)
- `ollama-init` (one-shot model pull)
- `mekeeli-api` (FastAPI on `http://localhost:8000`)
- `mekeeli-ui` (frontend on `http://localhost:3000`)
- `mekeeli-backup` (scheduled automated backups)

Useful URLs:
- UI: `http://localhost:3000`
- API health: `http://localhost:8000/health`
- Swagger docs: `http://localhost:8000/docs`
- ReDoc: `http://localhost:8000/redoc`

## Manual Docker commands

From repo root:

```bash
# start/rebuild (uses docker-compose.yml + docker-compose.override.yml automatically)
docker compose up -d --build

# stop stack
docker compose down

# stop + remove volumes
docker compose down -v

# logs
docker compose logs -f
docker compose logs -f mekeeli-api
docker compose logs -f mekeeli-ui
docker compose logs -f ollama
docker compose logs -f mekeeli-backup
```

## Environment files

The setup script ensures these files exist:
- `.env.local` (from `.env.template` if missing)
- `.env` (from `.env.local` if missing)
- `mekeeli-api/.env.local` (from `mekeeli-api/.env.template` if missing)

If you need custom values, edit those files before running `./setup.sh`.

## Automated backups

Backups are now automatic via the `mekeeli-backup` service.

What is backed up on each run:
- Postgres logical dump (`pg_dump`, gzipped)
- API app data volume (`/app/data`)
- uploads volume (`/app/uploads`, if populated)
- Ollama model store (`/root/.ollama`) when enabled

Backup output location:
- `./volumes/backups/<UTC_TIMESTAMP>/`

Configure schedule/retention in `.env.local`:
- `BACKUP_INTERVAL_SECONDS` (default `86400`, i.e. daily)
- `BACKUP_RETENTION_DAYS` (default `14`)
- `BACKUP_OLLAMA_MODELS` (`true|false`)

Useful commands:

```bash
# watch backup runs
docker compose logs -f mekeeli-backup

# force an on-demand backup
docker compose exec mekeeli-backup sh /scripts/backup_once.sh

# list available snapshots
ls -1 ./volumes/backups
```

## Restore after upgrade/failure

1) Stop app services (keep backup snapshots intact):

```bash
docker compose stop mekeeli-api mekeeli-ui mekeeli-backup
```

2) Pick a snapshot directory from `./volumes/backups`.

3) Restore database:

```bash
gzip -dc ./volumes/backups/<SNAPSHOT>/postgres.sql.gz | docker compose exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"
```

4) Restore file data:

```bash
mkdir -p ./volumes/mekeeli_data ./volumes/uploads ./volumes/ollama
tar -xzf ./volumes/backups/<SNAPSHOT>/app-data.tar.gz -C ./volumes/mekeeli_data
tar -xzf ./volumes/backups/<SNAPSHOT>/uploads-data.tar.gz -C ./volumes/uploads
tar -xzf ./volumes/backups/<SNAPSHOT>/ollama-data.tar.gz -C ./volumes/ollama
```

5) Bring services back:

```bash
docker compose up -d
```

Notes:
- Do not run `docker compose down -v` unless you explicitly intend to delete live volumes.
- For production upgrades, take an on-demand backup before updating images.

## Worker process (important)

The background worker exists in code (`mekeeli-api/worker.py`) but is not currently a dedicated Compose service.

If you need scheduled tasks/RAG ingestion ticking, run it manually:

```bash
docker compose exec mekeeli-api uv run python worker.py
```

## Project docs

- Technical spec: `TECHNICAL_SPECIFICATION.md`
- UI integration contract: `mekeeli-ui/UI_implementations.md`
- Backend module guide: `mekeeli-api/DEVELOPER_GUIDE.md`
- API contract: `mekeeli-ui/API_CONTRACT.md`
- Backend readme: `mekeeli-api/README.md`

## Troubleshooting

- Docker daemon not ready:
  - Start Docker Desktop (macOS) or Docker service (Linux), then re-run `./setup.sh`.
- Port conflicts:
  - Ensure `3000`, `8000`, `5432`, `11434` are free.
- Ollama models not available:
  - Check `docker compose logs -f ollama-init`.
- API imports fail for missing packages:
  - Rebuild API container: `docker compose up -d --build mekeeli-api`.

## Next deployment step

Current setup is local/dev focused. Planned next step is exposing `mekeeli-ui` via Nginx for web access.
