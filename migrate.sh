#!/usr/bin/env bash
set -e

# Detect environment: default = development
ENV=${1:-development}

if [ "$ENV" = "production" ]; then
  echo "🚀 Running migrations in production (Postgres)..."
  docker-compose --env-file .env exec api alembic upgrade head
else
  echo "🛠️ Running migrations in development (SQLite)..."
  DATABASE_URL=sqlite:///./sql.db alembic upgrade head
fi