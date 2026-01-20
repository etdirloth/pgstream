BEGIN;

-- prevent insertion of equal schemas into two successive versions
CREATE OR REPLACE FUNCTION pgstream.bi_schema_log_deduplicate()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog,pg_temp
AS $$
BEGIN
    IF NEW.schema = (
        SELECT previous_ver.schema
            FROM pgstream.schema_log AS previous_ver
            WHERE previous_ver.schema_name = NEW.schema_name
              AND previous_ver.version     < NEW.version
            ORDER BY version DESC
            LIMIT 1
       )
    THEN
        RETURN NULL;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER bi_schema_log_deduplicate
   BEFORE INSERT
   ON pgstream.schema_log
   FOR EACH ROW
   EXECUTE FUNCTION pgstream.bi_schema_log_deduplicate()
;

COMMIT;
