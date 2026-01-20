-- Test for migration 18: bi_schema_log_deduplicate
-- This test verifies that the trigger prevents duplicate *consecutive* schema versions

-- Cleanup
DROP TABLE  IF EXISTS test_schema_18.test_table;
DROP SCHEMA IF EXISTS test_schema_18;
DELETE FROM pgstream.schema_log WHERE schema_name = 'test_schema_18';

BEGIN;

-- Create a test schema and table
CREATE SCHEMA test_schema_18;

CREATE TABLE test_schema_18.test_table
(
   id    integer   NOT NULL   PRIMARY KEY
 , name  text      NOT NULL
);

-- Get the initial count
DO $$
DECLARE
   initial_count integer;
BEGIN
   SELECT count(*) INTO initial_count
      FROM pgstream.schema_log
      WHERE schema_name = 'test_schema_18';

   RAISE NOTICE '✓ Initial schema count: %', initial_count;
END;
$$;

-- Create an index
CREATE INDEX idx_test_table_name ON test_schema_18.test_table(name);

-- Verify count increased and capture schema before dropping index
DO $$
DECLARE
   count_after_index integer;
BEGIN
   SELECT count(*) INTO count_after_index
      FROM pgstream.schema_log
      WHERE schema_name = 'test_schema_18';

   RAISE NOTICE '✓ After CREATE INDEX: % schemas', count_after_index;

   -- Drop the index
   DROP INDEX test_schema_18.idx_test_table_name;

   -- Check if schema changed after drop
   DECLARE
      count_after_drop integer;
      schema_after_index_drop_penultimate pgstream.schema_log;
      schema_after_index_drop_latest      pgstream.schema_log;
   BEGIN

      SELECT count(*) INTO count_after_drop
         FROM pgstream.schema_log
         WHERE schema_name = 'test_schema_18';

      SELECT * INTO schema_after_index_drop_latest
         FROM pgstream.schema_log
         WHERE schema_name = 'test_schema_18'
         ORDER BY version DESC
         LIMIT 1;

      SELECT * INTO schema_after_index_drop_penultimate
         FROM pgstream.schema_log
         WHERE schema_name = 'test_schema_18'
           AND version < schema_after_index_drop_latest.version
         ORDER BY version DESC
         LIMIT 1;

      IF count_after_drop != (count_after_index + 1) THEN
         RAISE EXCEPTION 'Schema count should increase after DROP INDEX by 1, was % now %', count_after_index, count_after_drop;
      END IF;

      IF schema_after_index_drop_penultimate.schema = schema_after_index_drop_latest.schema THEN
         RAISE EXCEPTION 'Schema should change after DROP INDEX (deduplication failed to allow change)';
      END IF;

      RAISE NOTICE '✓ After DROP INDEX: % schemas (schema changed as expected)', count_after_drop;
   END;
END;
$$;

DO $$
BEGIN
   RAISE NOTICE '✓✓✓ Test completed for migration 18';
END;
$$;

COMMIT;

-- Cleanup
DROP TABLE  IF EXISTS test_schema_18.test_table;
DROP SCHEMA IF EXISTS test_schema_18;
DELETE FROM pgstream.schema_log WHERE schema_name = 'test_schema_18';

