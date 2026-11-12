-- Run progress tables. The backend writes these and the app only reads them (see R/modProgress.R).
-- @progress_schema is the schema the app is pointed at with PEGASUS_PROGRESS_SCHEMA. It has to be on the same
-- database as the data model, because the app joins phenotype_id to the phenotype table there.
DROP TABLE IF EXISTS @progress_schema.pegasus_run_step;
DROP TABLE IF EXISTS @progress_schema.pegasus_run;

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
