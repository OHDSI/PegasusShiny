# PegasusShiny

Shiny app for browsing, comparing and creating phenotypes in the OHDSI Pegasus data model. Phenotype Evaluation and
Generation by AI-assisted Synthesis & User Specifications (Pegasus).

The app was split out of [OHDSI/Pegasus](https://github.com/OHDSI/Pegasus) with its history kept.

## Running locally

1. Copy `.Renviron.example` to `.Renviron` and fill it in. DuckDB works for development.
2. Create the data model and (optionally) load the sample data, from `sql/`:
   - `CreateDataModel.sql` creates the tables (`@database_schema` is the schema to create them in).
   - `DevSeedData.sql` loads a small development data set.
   - `CreateProgressTables.sql` creates the backend's run progress tables and the run request table, in the same schema as the data model (`@database_schema`), and `DevSeedProgress.sql` loads a few sample runs, so the progress button on the Browse tab has something to show.
   - `MergeSchemasCheck.sql` and `MergeSchemas.sql` merge one Pegasus schema into another (set `@target_schema` and `@source_schema`), giving the source's colliding ids new ones. Run the check first.
   - `MigrateDataModel.sql` copies an older Pegasus schema into a new one (set `@old_schema` and `@new_schema`).
3. Start the app from this folder: `shiny::runApp()`.

## Run Pegasus (Beta)

The Run Pegasus (Beta) tab is where phenotypes are created, refined and run: it writes run requests for the backend to pick up. It needs the progress tables (see above), including `pegasus_run_request`. The databases it offers are the ones in `database_meta_data`.

## Tests

`testthat::test_dir("tests/testthat")` from the project root. The database tests build a DuckDB database from the files in `sql/`.

## Layout

- `ui.R`, `server.R`, `global.R`, `R/` – the app and its modules
- `skills/` – the system prompt for the phenotype chat
- `sql/` – data model, migration and development data
- `tests/` – testthat tests

## License

Apache License 2.0
