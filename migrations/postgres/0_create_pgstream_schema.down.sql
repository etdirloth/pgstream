-- Drop schema_migrations table if it exists
DROP TABLE IF EXISTS pgstream.schema_migrations;

----------------------------------------------------------------------------------------------------

-- Drop pgstream schema if it exists
DROP SCHEMA IF EXISTS pgstream CASCADE;
