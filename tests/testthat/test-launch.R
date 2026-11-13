# Creates the progress tables (and the dev rows when asked) next to the data model, in the same schema.
loadProgressTables <- function(pool, seed = FALSE) {
  files <- c("CreateProgressTables.sql", if (seed) "DevSeedProgress.sql")
  withConnection(pool, function(connection) {
    for (file in files) {
      sql <- SqlRender::render(SqlRender::readSql(file.path("..", "..", "sql", file)), progress_schema = "main")
      sql <- SqlRender::translate(sql, targetDialect = "duckdb")
      DatabaseConnector::executeSql(connection, sql, progressBar = FALSE, reportOverallTime = FALSE)
    }
  })
}

checklistFor <- function(...) {
  arguments <- list(
    intent = "NEW_PHENOTYPE", name = "Gout", description = "Gout is ...", phenotypeId = NA_integer_,
    databaseIds = 1L, maxCores = NA, existingNames = c("Asthma"), hasActiveRun = FALSE, signedIn = TRUE
  )
  arguments[names(list(...))] <- list(...)
  do.call(launchChecklist, arguments)
}

test_that("launchChecklist is all ok for a complete new phenotype and a complete re-run", {
  expect_true(all(checklistFor()$ok))
  expect_true(all(checklistFor(intent = "RERUN", phenotypeId = 1L, name = "", description = "")$ok))
})

test_that("a new phenotype that the refinement already saved only needs its run settings", {
  checks <- checklistFor(name = "", description = "", phenotypeId = 7L)
  expect_true(all(checks$ok))
  expect_true("Phenotype saved" %in% checks$item)
  expect_false("Phenotype name" %in% checks$item)
  expect_equal(checklistFor(name = "", description = "", phenotypeId = 7L, databaseIds = NULL)$item[
    !checklistFor(name = "", description = "", phenotypeId = 7L, databaseIds = NULL)$ok], "Databases")
})

test_that("launchChecklist names what is missing", {
  failing <- function(...) checklistFor(...)$item[!checklistFor(...)$ok]
  expect_equal(failing(name = " "), "Phenotype name")
  expect_equal(failing(name = "asthma"), "Phenotype name") # existing names are matched without regard to case
  expect_equal(failing(description = ""), "Clinical definition")
  expect_equal(failing(databaseIds = NULL), "Databases")
  expect_equal(failing(maxCores = 0), "Cores")
  expect_equal(failing(maxCores = 2.5), "Cores")
  expect_equal(failing(maxCores = 99), "Cores")
  expect_equal(failing(signedIn = FALSE), "Signed in")
  expect_equal(failing(intent = "RERUN"), "Phenotype chosen")
  expect_equal(failing(intent = "RERUN", phenotypeId = 1L, hasActiveRun = TRUE), "No run in progress")
})

test_that("buildRunRequest leaves empty optional settings NA and writes the databases as a JSON array", {
  request <- buildRunRequest(7, "RERUN", 3, c(11, 12), llmModel = " ", maxCores = NULL, requestedBy = "me")
  expect_equal(request$databaseIds, "[11,12]")
  expect_true(is.na(request$llmModel))
  expect_true(is.na(request$maxCores))
  expect_equal(request$status, "REQUESTED")
  databases <- data.frame(databaseId = c(11L, 12L), databaseLabel = c("A", "B (v2)"))
  expect_equal(requestDatabaseLabels(request$databaseIds, databases), "A, B (v2)")
  expect_equal(requestDatabaseLabels("[11,99]", databases), "A, #99") # an id that is not (any longer) known
  expect_equal(requestDatabaseLabels("not json", databases), "")
  expect_equal(buildRunRequest(1, "RERUN", 1, 11L, llmModel = " o3 ", maxCores = 6, requestedBy = "me")$llmModel, "o3")
  # A single database is still an array
  expect_equal(buildRunRequest(1, "RERUN", 1, 11L, requestedBy = "me")$databaseIds, "[11]")
})

test_that("requestStatusLabel follows the request and then its run", {
  labels <- requestStatusLabel(c("REQUESTED", "REJECTED", "CLAIMED", "CLAIMED", "CLAIMED"),
                               c(NA, NA, NA, "RUNNING", "DONE"))
  expect_match(labels[1], "Waiting for the backend")
  expect_match(labels[2], "Rejected")
  expect_match(labels[3], "Started")
  expect_match(labels[4], "Running")
  expect_match(labels[5], "text-bg-success")
})

test_that("submitRunRequest creates the phenotype for a new one and saves the request", {
  pool <- createTestPool()
  on.exit(pool::poolClose(pool))
  loadSeedData(pool)
  loadProgressTables(pool)

  result <- withConnection(pool, function(connection) {
    submitRunRequest(connection, "main", "main", "NEW_PHENOTYPE", name = "Gout", description = "Gout is ...",
                     databaseIds = c(1L, 2L), maxCores = 2, requestedBy = "me")
  })
  expect_equal(result$runRequestId, 1)
  phenotype <- withConnection(pool, function(connection) getPhenotypes(connection, "main"))
  expect_true("Gout" %in% phenotype$phenotypeName)

  requests <- withConnection(pool, function(connection) getRunRequests(connection, "main", "main"))
  expect_equal(nrow(requests), 1)
  expect_equal(requests$phenotypeName, "Gout")
  expect_equal(requests$status, "REQUESTED")
  expect_equal(requests$requestType, "NEW_PHENOTYPE")
  expect_equal(requests$databaseIds, "[1,2]")
  expect_true(is.na(requests$runStatus))

  # A name that is taken is reported before anything is requested
  expect_error(withConnection(pool, function(connection) {
    submitRunRequest(connection, "main", "main", "NEW_PHENOTYPE", name = "gout", description = "x",
                     databaseIds = 1L, requestedBy = "me")
  }), "already exists")
  expect_equal(nrow(withConnection(pool, function(connection) getRunRequests(connection, "main", "main"))), 1)

  # A re-run uses the phenotype as it is and gets the next id
  again <- withConnection(pool, function(connection) {
    submitRunRequest(connection, "main", "main", "RERUN", phenotypeId = 1L, databaseIds = 3L, requestedBy = "me")
  })
  expect_equal(again$runRequestId, 2)
  expect_equal(nrow(withConnection(pool, function(connection) getRunRequests(connection, "main", "main"))), 2)
  expect_error(withConnection(pool, function(connection) {
    submitRunRequest(connection, "main", "main", "RERUN", databaseIds = 3L, requestedBy = "me")
  }), "Choose the phenotype")
  expect_error(withConnection(pool, function(connection) {
    submitRunRequest(connection, "main", "main", "RERUN", phenotypeId = 1L, databaseIds = integer(0), requestedBy = "me")
  }), "at least one database")
})

test_that("the seeded requests are read with the status of their runs", {
  pool <- createTestPool()
  on.exit(pool::poolClose(pool))
  loadSeedData(pool)
  loadProgressTables(pool, seed = TRUE)
  requests <- withConnection(pool, function(connection) getRunRequests(connection, "main", "main"))
  expect_equal(sort(requests$status), c("CLAIMED", "CLAIMED", "CLAIMED", "CLAIMED", "REJECTED", "REQUESTED"))
  expect_equal(requests$message[requests$status == "REJECTED"], "Database id(s) not in database_meta_data: [999]")
  # A claimed request shows the status of its run
  expect_equal(requests$runStatus[requests$runRequestId == 1], "RUNNING")
  # Every database a seeded request names, other than the rejected one, is in the data model
  ids <- unique(unlist(lapply(requests$databaseIds[requests$status != "REJECTED"], jsonlite::fromJSON)))
  known <- withConnection(pool, function(connection) getDatabases(connection, "main"))$databaseId
  expect_true(all(ids %in% known))
})

test_that("the launch server launches a request only when the checklist is complete", {
  pool <- createTestPool()
  on.exit(pool::poolClose(pool))
  loadSeedData(pool)
  loadProgressTables(pool, seed = TRUE)
  phenotypes <- reactiveVal(withConnection(pool, function(connection) getPhenotypeSummary(connection, "main")))
  refreshed <- 0

  testServer(
    launchServer,
    args = list(
      connectionPool = pool, databaseSchema = "main", progressSchema = "main", userName = "me",
      phenotypes = phenotypes, refreshPhenotypes = function() refreshed <<- refreshed + 1
    ),
    {
      session$setInputs(intent = "NEW_PHENOTYPE", name = "Gout", description = "", databases = "1", maxCores = NA,
                        llmModel = "", llmFrontierModel = "", onlyMine = FALSE)
      expect_false(all(checklist()$ok))
      session$setInputs(launch = 1)
      expect_equal(nrow(requests()), 6) # nothing was saved: the definition is empty

      session$setInputs(description = "Gout is ...", launch = 2)
      expect_equal(nrow(requests()), 7)
      expect_equal(refreshed, 1)
      expect_true("Gout" %in% withConnection(pool, function(connection) getPhenotypes(connection, "main"))$phenotypeName)
    }
  )
})

test_that("the refine button sends the name and definition away, and the saved phenotype comes back chosen", {
  pool <- createTestPool()
  on.exit(pool::poolClose(pool))
  loadSeedData(pool)
  loadProgressTables(pool, seed = TRUE)
  phenotypes <- reactiveVal(withConnection(pool, function(connection) getPhenotypeSummary(connection, "main")))
  preselect <- reactiveVal(NULL)
  sent <- NULL

  testServer(
    launchServer,
    args = list(
      connectionPool = pool, databaseSchema = "main", progressSchema = "main", userName = "me",
      phenotypes = phenotypes, refreshPhenotypes = function() NULL,
      onRefine = function(name, definition) sent <<- list(name = name, definition = definition), preselect = preselect
    ),
    {
      session$setInputs(intent = "NEW_PHENOTYPE", name = " ", description = "x", databases = "1", maxCores = NA,
                        llmModel = "", llmFrontierModel = "", onlyMine = FALSE, refine = 1)
      expect_null(sent) # a name is needed
      session$setInputs(name = "asthma", refine = 2)
      expect_null(sent) # and it must not be taken
      session$setInputs(name = "Gout", description = "Gout is ...", refine = 3)
      expect_equal(sent, list(name = "Gout", definition = "Gout is ..."))

      # The wizard saved a phenotype (here an existing one) and the tab is shown again
      preselect(list(id = 7L, nonce = 1))
      session$flushReact()
      expect_equal(savedPhenotypeId(), 7L)
      expect_true(all(checklist()$ok))

      session$setInputs(clearSaved = 1)
      expect_true(is.na(savedPhenotypeId()))
    }
  )
})

test_that("a saved new phenotype is launched without being created again", {
  pool <- createTestPool()
  on.exit(pool::poolClose(pool))
  loadSeedData(pool)
  loadProgressTables(pool)
  before <- nrow(withConnection(pool, function(connection) getPhenotypes(connection, "main")))
  result <- withConnection(pool, function(connection) {
    submitRunRequest(connection, "main", "main", "NEW_PHENOTYPE", phenotypeId = 7L, databaseIds = 1L, requestedBy = "me")
  })
  expect_equal(result$phenotypeId, 7L)
  expect_equal(nrow(withConnection(pool, function(connection) getPhenotypes(connection, "main"))), before)
  request <- withConnection(pool, function(connection) getRunRequests(connection, "main", "main"))
  expect_equal(c(request$requestType, request$phenotypeId), c("NEW_PHENOTYPE", 7))
})

test_that("the user-supplied cohort definition shows in the summary steps, greyed out, before the evaluation", {
  steps <- launchSummarySteps()
  expect_equal(length(steps), length(launchPipelineSteps) + 1)
  expect_equal(steps[length(steps) - 1], launchUserDefinitionStep)
  expect_equal(steps[length(steps)], "Evaluation")
  expect_equal(setdiff(steps, launchUserDefinitionStep), launchPipelineSteps)
  # It is no longer one of the disabled options in the advanced settings
  expect_false(any(grepl("Add my own", launchUnavailableOptions)))
})

test_that("the form has the cohort definition step with its notice, and the tab can show the wizard instead", {
  html <- as.character(launchUi("launch"))
  expect_match(html, "4. Cohort definition", fixed = TRUE)
  expect_match(html, "does not run user-supplied cohort definitions yet", fixed = TRUE)
  for (id in c("launch-cohortName", "launch-circeJson", "launch-atlasId", "launch-jsonStatus")) {
    expect_match(html, id, fixed = TRUE)
  }
  expect_match(html, "5. Advanced settings", fixed = TRUE)
  expect_false(grepl("Add my own cohort definitions", html, fixed = TRUE))

  # createUi needs packages the tests do not otherwise use, so a stand-in is used for the wizard
  original <- get("createUi", globalenv())
  assign("createUi", function(id) tags$div(id = paste0(id, "-wizard")), globalenv())
  on.exit(assign("createUi", original, globalenv()))
  tab <- as.character(launchTabUi())
  for (id in c("launchView", "launchBack", "create-wizard", "launch-circeJson")) {
    expect_match(tab, id, fixed = TRUE)
  }
})

test_that("a cohort definition that is entered is noticed but does not change the checklist", {
  pool <- createTestPool()
  on.exit(pool::poolClose(pool))
  loadSeedData(pool)
  loadProgressTables(pool)
  phenotypes <- reactiveVal(withConnection(pool, function(connection) getPhenotypeSummary(connection, "main")))
  testServer(
    launchServer,
    args = list(connectionPool = pool, databaseSchema = "main", progressSchema = "main", userName = "me",
                phenotypes = phenotypes, refreshPhenotypes = function() NULL),
    {
      session$setInputs(intent = "RERUN", phenotype = "1", databases = "1", maxCores = NA, circeJson = "")
      expect_false(hasCohortDefinition())
      expect_true(all(checklist()$ok))
      session$setInputs(circeJson = '{"PrimaryCriteria": {}}')
      expect_true(hasCohortDefinition())
      expect_true(all(checklist()$ok)) # still launchable: the definition is simply not sent
    }
  )
})
