#!/bin/sh
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -v app_password="$POSTGRES_APP_PASSWORD" <<'SQL'
CREATE ROLE grownic_app LOGIN PASSWORD :'app_password';
\i /grownic-sql/001_schema.sql
\i /grownic-sql/002_operations.sql
INSERT INTO grownic.settings(config) VALUES(pg_read_file('/grownic-client.json')::jsonb);
GRANT USAGE ON SCHEMA grownic TO grownic_app;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA grownic TO grownic_app;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA grownic TO grownic_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA grownic TO grownic_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL
