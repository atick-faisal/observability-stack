-- Creates the role postgres_exporter connects as. Reads the password from the
-- environment with \getenv, so one file works in both places it is needed:
--
--   fresh volume    mount it at /docker-entrypoint-initdb.d/ and set
--                   POSTGRES_EXPORTER_PASSWORD on the postgres container
--
--   existing db     POSTGRES_EXPORTER_PASSWORD=... docker compose exec -T db \
--                     psql -U postgres -d appdb -f - < observability/postgres-exporter-init.sql
--
-- Re-running is safe: an existing role has its password rotated rather than
-- failing the script.

\set ON_ERROR_STOP on
\getenv exporter_password POSTGRES_EXPORTER_PASSWORD

\if :{?exporter_password}
\else
\warn 'POSTGRES_EXPORTER_PASSWORD is not set'
\quit
\endif

SELECT format(
    '%s ROLE postgres_exporter LOGIN PASSWORD %L',
    CASE
        WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres_exporter')
        THEN 'ALTER'
        ELSE 'CREATE'
    END,
    :'exporter_password'
) \gexec

SELECT format(
    'GRANT CONNECT ON DATABASE %I TO postgres_exporter', current_database()
) \gexec

-- pg_monitor carries pg_stat_checkpointer, which is where PG17+ moved the
-- checkpoint counters. Without it the exporter runs but those series are absent.
GRANT pg_monitor TO postgres_exporter;

-- The exporter's own convention: keep any helper views it needs out of public.
ALTER ROLE postgres_exporter SET search_path TO postgres_exporter, pg_catalog;
