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
    databaseNames = "DEVCLM", maxCores = NA, existingNames = c("Asthma"), hasActiveRun = FALSE, signedIn = TRUE
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
  expect_equal(checklistFor(name = "", description = "", phenotypeId = 7L, databaseNames = NULL)$item[
    !checklistFor(name = "", description = "", phenotypeId = 7L, databaseNames = NULL)$ok], "Databases")
})

test_that("launchChecklist names what is missing", {
  failing <- function(...) checklistFor(...)$item[!checklistFor(...)$ok]
  expect_equal(failing(name = " "), "Phenotype name")
  expect_equal(failing(name = "asthma"), "Phenotype name") # existing names are matched without regard to case
  expect_equal(failing(description = ""), "Clinical definition")
  expect_equal(failing(databaseNames = NULL), "Databases")
  expect_equal(failing(maxCores = 0), "Cores")
  expect_equal(failing(maxCores = 2.5), "Cores")
  expect_equal(failing(maxCores = 99), "Cores")
  expect_equal(failing(signedIn = FALSE), "Signed in")
  expect_equal(failing(intent = "RERUN"), "Phenotype chosen")
  expect_equal(failing(intent = "RERUN", phenotypeId = 1L, hasActiveRun = TRUE), "No run in progress")
})

test_that("buildRunRequest leaves empty optional settings NA and writes the databases as a JSON array", {
  request <- buildRunRequest(7, "RERUN", 3, c("A", "B"), llmModel = " ", maxCores = NULL, requestedBy = "me")
  expect_equal(request$databaseNames, '["A","B"]')
  expect_true(is.na(request$llmModel))
  expect_true(is.na(request$maxCores))
  expect_equal(request$status, "REQUESTED")
  expect_equal(parseDatabaseNames(request$databaseNames), "A, B")
  expect_equal(parseDatabaseNames("not json"), "")
  expect_equal(buildRunRequest(1, "RERUN", 1, "A", llmModel = " o3 ", maxCores = 6, requestedBy = "me")$llmModel, "o3")
  # A single database is still an array
  expect_equal(buildRunRequest(1, "RERUN", 1, "A", requestedBy = "me")$databaseNames, '["A"]')
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
                     databaseNames = c("DEVCLM", "DEVEHR"), maxCores = 2, requestedBy = "me")
  })
  expect_equal(result$runRequestId, 1)
  phenotype <- withConnection(pool, function(connection) getPhenotypes(connection, "main"))
  expect_true("Gout" %in% phenotype$phenotypeName)

  requests <- withConnection(pool, function(connection) getRunRequests(connection, "main", "main"))
  expect_equal(nrow(requests), 1)
  expect_equal(requests$phenotypeName, "Gout")
  expect_equal(requests$status, "REQUESTED")
  expect_equal(requests$requestType, "NEW_PHENOTYPE")
  expect_equal(parseDatabaseNames(requests$databaseNames), "DEVCLM, DEVEHR")
  expect_true(is.na(requests$runStatus))

  # A name that is taken is reported before anything is requested
  expect_error(withConnection(pool, function(connection) {
    submitRunRequest(connection, "main", "main", "NEW_PHENOTYPE", name = "gout", description = "x",
                     databaseNames = "DEVCLM", requestedBy = "me")
  }), "already exists")
  expect_equal(nrow(withConnection(pool, function(connection) getRunRequests(connection, "main", "main"))), 1)

  # A re-run uses the phenotype as it is and gets the next id
  again <- withConnection(pool, function(connection) {
    submitRunRequest(connection, "main", "main", "RERUN", phenotypeId = 1L, databaseNames = "DEVREG", requestedBy = "me")
  })
  expect_equal(again$runRequestId, 2)
  expect_equal(nrow(withConnection(pool, function(connection) getRunRequests(connection, "main", "main"))), 2)
  expect_error(withConnection(pool, function(connection) {
    submitRunRequest(connection, "main", "main", "RERUN", databaseNames = "DEVREG", requestedBy = "me")
  }), "Choose the phenotype")
  expect_error(withConnection(pool, function(connection) {
    submitRunRequest(connection, "main", "main", "RERUN", phenotypeId = 1L, databaseNames = character(0), requestedBy = "me")
  }), "at least one database")
})

test_that("the registry and the seeded requests are read, and a missing registry is empty", {
  pool <- createTestPool()
  on.exit(pool::poolClose(pool))
  loadSeedData(pool)

  expect_equal(nrow(withConnection(pool, function(connection) getRegisteredDatabases(connection, "main"))), 0)

  loadProgressTables(pool, seed = TRUE)
  registry <- withConnection(pool, function(connection) getRegisteredDatabases(connection, "main"))
  expect_equal(registry$databaseName, c("DEVCLM", "DEVEHR", "DEVREG"))
  requests <- withConnection(pool, function(connection) getRunRequests(connection, "main", "main"))
  expect_equal(sort(requests$status), c("CLAIMED", "CLAIMED", "CLAIMED", "CLAIMED", "REJECTED", "REQUESTED"))
  expect_equal(requests$message[requests$status == "REJECTED"], "Unknown database(s): ['OLDDB']")
  # A claimed request shows the status of its run
  expect_equal(requests$runStatus[requests$runRequestId == 1], "RUNNING")
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
      session$setInputs(intent = "NEW_PHENOTYPE", name = "Gout", description = "", databases = "DEVCLM", maxCores = NA,
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
      session$setInputs(intent = "NEW_PHENOTYPE", name = " ", description = "x", databases = "DEVCLM", maxCores = NA,
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
    submitRunRequest(connection, "main", "main", "NEW_PHENOTYPE", phenotypeId = 7L, databaseNames = "DEVCLM", requestedBy = "me")
  })
  expect_equal(result$phenotypeId, 7L)
  expect_equal(nrow(withConnection(pool, function(connection) getPhenotypes(connection, "main"))), before)
  request <- withConnection(pool, function(connection) getRunRequests(connection, "main", "main"))
  expect_equal(c(request$requestType, request$phenotypeId), c("NEW_PHENOTYPE", 7))
})
