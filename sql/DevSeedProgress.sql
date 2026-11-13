-- Development data for the run progress tables (see CreateProgressTables.sql): runs and steps in each state, the
-- databases the backend offers, and requests that are waiting, claimed and rejected. The phenotype_id values are those of
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

INSERT INTO @progress_schema.pegasus_database_registry (database_name, description) VALUES
  ('DEVCLM', 'Dev Claims Database'),
  ('DEVEHR', 'Dev EHR Database'),
  ('DEVREG', 'Dev Registry');

INSERT INTO @progress_schema.pegasus_run_request (run_request_id, request_type, phenotype_id, database_names, llm_model, llm_frontier_model, max_cores, request_options, requested_by, time_requested, status, run_id, message) VALUES
  (1, 'RERUN', 1, '["DEVCLM","DEVEHR"]', NULL, NULL, 4, NULL, 'developer', DATEADD(minute, -21, CAST(CURRENT_TIMESTAMP AS DATETIME)), 'CLAIMED', 1, NULL),
  (2, 'RERUN', 2, '["DEVCLM"]', NULL, NULL, NULL, NULL, 'developer', DATEADD(minute, -2, CAST(CURRENT_TIMESTAMP AS DATETIME)), 'CLAIMED', 2, NULL),
  (3, 'NEW_PHENOTYPE', 7, '["DEVEHR"]', NULL, NULL, NULL, NULL, 'developer', DATEADD(minute, -1, CAST(CURRENT_TIMESTAMP AS DATETIME)), 'REQUESTED', NULL, NULL),
  -- Run 3 failed, and run 4 finished long ago
  (4, 'NEW_PHENOTYPE', 5, '["DEVCLM","DEVEHR","DEVREG"]', 'o3-mini', 'o3', 8, NULL, 'developer', DATEADD(hour, -3, CAST(CURRENT_TIMESTAMP AS DATETIME)), 'CLAIMED', 3, NULL),
  (5, 'RERUN', 8, '["DEVREG"]', NULL, NULL, NULL, NULL, 'analyst', DATEADD(day, -5, CAST(CURRENT_TIMESTAMP AS DATETIME)), 'CLAIMED', 4, NULL),
  (6, 'RERUN', 6, '["OLDDB"]', NULL, NULL, NULL, NULL, 'analyst', DATEADD(day, -1, CAST(CURRENT_TIMESTAMP AS DATETIME)), 'REJECTED', NULL, 'Unknown database(s): [''OLDDB'']');
