BEGIN;

DROP TRIGGER IF EXISTS bi_schema_log_deduplicate ON pgstream.schema_log;
DROP FUNCTION pgstream.bi_schema_log_deduplicate();

COMMIT;
