# The demo database with the exporter's role-creation script baked in.
#
# Build context is the repo root, so the script stays shared with agent/ rather
# than copied: agent/postgres-exporter-init.sql is the same file compose.demo.yml
# bind-mounts locally.
#
#   docker build -f demo/db/Dockerfile .
#
# It exists because a bind mount does not survive a platform that re-clones the
# repo on every deploy — the same reason agent/Dockerfile does, and the pattern any
# app in that position needs for its own database.
#
# Runs once, on a fresh volume, and reads POSTGRES_EXPORTER_PASSWORD from the
# environment via psql's \getenv.
FROM postgres:18-alpine

COPY agent/postgres-exporter-init.sql /docker-entrypoint-initdb.d/10-postgres-exporter.sql
