-- Create pgstream schema if it does not exist
-- NOTE: This migration (version 0) is compatible with golang-migrate.
-- golang-migrate creates the schema separately before running migrations (starting at version 1).
-- The IF NOT EXISTS clauses ensure idempotency regardless of execution order.
CREATE SCHEMA IF NOT EXISTS pgstream;

COMMENT ON SCHEMA pgstream IS 'Schema for pgstream internal objects and functions';

----------------------------------------------------------------------------------------------------

-- Create schema_migrations table if it does not exist
-- This table is used by golang-migrate to track the current migration version
CREATE TABLE IF NOT EXISTS pgstream.schema_migrations
(
   version   bigint      NOT NULL   PRIMARY KEY
 , dirty     boolean     NOT NULL   DEFAULT false
);

COMMENT ON TABLE  pgstream.schema_migrations         IS 'Tracks the current database migration version for golang-migrate';
COMMENT ON COLUMN pgstream.schema_migrations.version IS 'Current migration version number';
COMMENT ON COLUMN pgstream.schema_migrations.dirty   IS 'Indicates if a migration failed partway through';
