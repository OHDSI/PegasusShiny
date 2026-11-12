-- Development data for the run progress tables (see CreateProgressTables.sql). The phenotype_id values are those of
-- DevSeedData.sql. Run it after both of the scripts, with @progress_schema set.
-- Times are relative to now, so the failed run stays inside the day the app keeps showing failures for. The
-- timestamp is cast to DATETIME because DATEADD on a timestamp with time zone fails on DuckDB, and GETDATE() would
-- become a date without the time of day on PostgreSQL.

INSERT INTO @progress_schema.pegasus_run (run_id, phenotype_id, status, time_submitted, time_finished, error) VALUES
  (1, 1, 'RUNNING', DATEADD(minute, -20, CAST(CURRENT_TIMESTAMP AS DATETIME)), NULL, NULL),
  (2, 2, 'SUBMITTED', DATEADD(minute, -2, CAST(CURRENT_TIMESTAMP AS DATETIME)), NULL, NULL),
  (3, 5, 'FAILED', DATEADD(hour, -3, CAST(CURRENT_TIMESTAMP AS DATETIME)), DATEADD(hour, -2, CAST(CURRENT_TIMESTAMP AS DATETIME)), 'Cohort generation failed: timed out waiting for the database'),
  -- Finished long ago, so not shown
  (4, 8, 'DONE', DATEADD(day, -5, CAST(CURRENT_TIMESTAMP AS DATETIME)), DATEADD(day, -5, CAST(CURRENT_TIMESTAMP AS DATETIME)), NULL);

INSERT INTO @progress_schema.pegasus_run_step (run_id, step_index, step_name, status) VALUES
  (1, 1, 'Generate phenotype metadata', 'DONE'),
  (1, 2, 'Build concept sets', 'DONE'),
  (1, 3, 'Build cohort definitions', 'RUNNING'),
  (1, 4, 'Evaluate cohorts', 'PENDING'),
  (2, 1, 'Generate phenotype metadata', 'PENDING'),
  (2, 2, 'Build concept sets', 'PENDING'),
  (2, 3, 'Build cohort definitions', 'PENDING'),
  (2, 4, 'Evaluate cohorts', 'PENDING'),
  (3, 1, 'Generate phenotype metadata', 'DONE'),
  (3, 2, 'Build concept sets', 'DONE'),
  (3, 3, 'Build cohort definitions', 'FAILED'),
  (3, 4, 'Evaluate cohorts', 'PENDING'),
  (4, 1, 'Generate phenotype metadata', 'DONE'),
  (4, 2, 'Build concept sets', 'DONE'),
  (4, 3, 'Build cohort definitions', 'DONE'),
  (4, 4, 'Evaluate cohorts', 'DONE');
