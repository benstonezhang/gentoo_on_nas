DO $do$
BEGIN
  EXECUTE (
    SELECT string_agg(format('ALTER TABLE %I.%I RESET (autovacuum_enabled)', schemaname, tablename), '; ')
    FROM   pg_tables
    WHERE  schemaname NOT LIKE 'pg\_%'
    AND    schemaname <> 'information_schema'
  );
END
$do$;
