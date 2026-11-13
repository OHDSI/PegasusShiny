# PegasusShiny

Shiny app for browsing, comparing and creating phenotypes in the OHDSI Pegasus data model. Phenotype Evaluation and
Generation by AI-assisted Synthesis & User Specifications (Pegasus).

The app was split out of [OHDSI/Pegasus](https://github.com/OHDSI/Pegasus) with its history kept.

## Running locally

1. Copy `.Renviron.example` to `.Renviron` and fill it in. DuckDB works for development.
2. Create the data model and (optionally) load the sample data, from `sql/`:
   - `CreateDataModel.sql` creates the tables (`@database_schema` is the schema to create them in).
   - `DevSeedData.sql` loads a small development data set.
   - `CreateProgressTables.sql` creates the backend's run progress tables (`@progress_schema`, set with `PEGASUS_PROGRESS_SCHEMA`; the data model schema when that is not set) and `DevSeedProgress.sql` loads a few sample runs, so the progress button on the Browse tab has something to show.
   - `MigrateDataModel.sql` copies an older Pegasus schema into a new one (set `@old_schema` and `@new_schema`).
3. Start the app from this folder: `shiny::runApp()`.

## Run Pegasus (Beta)

Set `PEGASUS_ENABLE_LAUNCH=true` to show the Run Pegasus (Beta) tab, which writes run requests for the backend to pick up. It needs the progress tables (see above), including `pegasus_run_request` and `pegasus_database_registry`.

## Tests

`testthat::test_dir("tests/testthat")` from the project root. The database tests build a DuckDB database from the files in `sql/`.

## Layout

- `ui.R`, `server.R`, `global.R`, `R/` – the app and its modules
- `skills/` – the system prompt for the phenotype chat
- `sql/` – data model, migration and development data
- `tests/` – testthat tests

## License

Apache License 2.0
