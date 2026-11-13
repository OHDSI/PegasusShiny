-- Run progress tables. The backend writes pegasus_run and pegasus_run_step and the app reads them (see
-- R/modProgress.R). The app writes pegasus_run_request (see R/modLaunch.R) and the backend reads and claims it.
-- @progress_schema is the schema the app is pointed at with PEGASUS_PROGRESS_SCHEMA. It has to be on the same
-- database as the data model, because the app joins phenotype_id to the phenotype table there. The schema is created
-- if it does not exist (this needs the right to create schemas; if you do not have it, create the schema first).
CREATE SCHEMA IF NOT EXISTS @progress_schema;

DROP TABLE IF EXISTS @progress_schema.pegasus_run_step;
DROP TABLE IF EXISTS @progress_schema.pegasus_run;
DROP TABLE IF EXISTS @progress_schema.pegasus_run_request;
DROP TABLE IF EXISTS @progress_schema.pegasus_database_registry;

-- One row per run of a phenotype. The app shows only the latest run (highest run_id) of each phenotype, and only
-- while it is SUBMITTED or RUNNING, or for a day after it FAILED.
CREATE TABLE @progress_schema.pegasus_run (
  run_id INT PRIMARY KEY,
  phenotype_id INT NOT NULL,
  status VARCHAR NOT NULL, -- 'SUBMITTED', 'RUNNING', 'DONE', or 'FAILED'
  time_submitted DATETIME NOT NULL,
  time_finished DATETIME,
  error VARCHAR
);

-- The pipeline steps of a run, in step_index order
CREATE TABLE @progress_schema.pegasus_run_step (
  run_id INT NOT NULL,
  step_index INT NOT NULL,
  step_name VARCHAR NOT NULL,
  status VARCHAR NOT NULL -- 'PENDING', 'RUNNING', 'DONE', or 'FAILED'
);

-- A request to run the pipeline, written by the app's Run Pegasus tab. The backend's queue poller turns each
-- REQUESTED row into a pegasus_run and a pegasus-workflow flow run, then sets status to CLAIMED and run_id.
-- The phenotype already exists in the data model when the request is written.
CREATE TABLE @progress_schema.pegasus_run_request (
  run_request_id INT PRIMARY KEY,
  request_type VARCHAR NOT NULL, -- 'NEW_PHENOTYPE' or 'RERUN'
  phenotype_id INT NOT NULL,
  database_names VARCHAR NOT NULL, -- JSON array of names from pegasus_database_registry
  llm_model VARCHAR, -- NULL: the backend's default
  llm_frontier_model VARCHAR, -- NULL: the backend's default
  max_cores INT, -- NULL: the backend's default
  request_options VARCHAR, -- JSON object for options that are not columns (yet); NULL when there are none
  requested_by VARCHAR NOT NULL,
  time_requested DATETIME NOT NULL,
  status VARCHAR NOT NULL, -- 'REQUESTED', 'CLAIMED', or 'REJECTED'
  run_id INT, -- the pegasus_run created for the request, once CLAIMED
  message VARCHAR -- why a request was REJECTED
);

-- The databases the backend can run against (the keys of its pegasus-databases secret; names only, no
-- connection details). Published by the backend so the app can offer them before any run has uploaded
-- database_meta_data for them.
CREATE TABLE @progress_schema.pegasus_database_registry (
  database_name VARCHAR PRIMARY KEY,
  description VARCHAR
);
