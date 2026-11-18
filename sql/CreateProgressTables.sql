-- Run progress tables. The backend writes pegasus_run and pegasus_run_step and the app reads them (see
-- R/modProgress.R). The app writes pegasus_run_request (see R/modLaunch.R) and the backend reads and claims it.
-- The tables live in the same schema as the data model (@database_schema), so there is a single Pegasus schema.
-- Run CreateDataModel.sql first; the app joins phenotype_id to the phenotype table there.

DROP TABLE IF EXISTS @database_schema.pegasus_run_step;
DROP TABLE IF EXISTS @database_schema.pegasus_run;
DROP TABLE IF EXISTS @database_schema.pegasus_run_request;

-- One row per run of a phenotype. The app shows only the latest run (highest run_id) of each phenotype, and only
-- while it is SUBMITTED or RUNNING, or for a day after it FAILED.
CREATE TABLE @database_schema.pegasus_run (
  run_id INT PRIMARY KEY,
  phenotype_id INT NOT NULL,
  status VARCHAR NOT NULL, -- 'SUBMITTED', 'RUNNING', 'DONE', or 'FAILED'
  time_submitted DATETIME NOT NULL,
  time_finished DATETIME,
  error VARCHAR
);

-- The pipeline steps of a run, in step_index order
CREATE TABLE @database_schema.pegasus_run_step (
  run_id INT NOT NULL,
  step_index INT NOT NULL,
  step_name VARCHAR NOT NULL,
  status VARCHAR NOT NULL -- 'PENDING', 'RUNNING', 'DONE', or 'FAILED'
);

-- A request to run the pipeline, written by the app's Run Pegasus tab. The backend's queue poller turns each
-- REQUESTED row into a pegasus_run and a pegasus-workflow flow run, then sets status to CLAIMED and run_id.
-- The phenotype already exists in the data model when the request is written.
CREATE TABLE @database_schema.pegasus_run_request (
  run_request_id INT PRIMARY KEY,
  request_type VARCHAR NOT NULL, -- 'NEW_PHENOTYPE' or 'RERUN'
  phenotype_id INT NOT NULL,
  database_ids VARCHAR NOT NULL, -- JSON array of database_id values from database_meta_data in the data model
  llm_model VARCHAR, -- NULL: the backend's default
  llm_frontier_model VARCHAR, -- NULL: the backend's default
  max_cores INT, -- NULL: the backend's default
  request_options VARCHAR, -- JSON object for options that are not columns (yet), e.g. {"cohortCreationApproaches": ["templates", "monoflow"]} (an empty array: only evaluate)
  requested_by VARCHAR NOT NULL,
  time_requested DATETIME NOT NULL,
  status VARCHAR NOT NULL, -- 'REQUESTED', 'CLAIMED', or 'REJECTED'
  run_id INT, -- the pegasus_run created for the request, once CLAIMED
  message VARCHAR -- why a request was REJECTED
);
