# Copyright 2026 Observational Health Data Sciences and Informatics
#
# This file is part of Pegasus
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and

# Progress of backend Pegasus runs (see the ohda-pegasus flows). The backend queues a phenotype's run in
# pegasus_run and records each pipeline step in pegasus_run_step. Both tables are created by the backend, in its own
# schema (PEGASUS_PROGRESS_SCHEMA; the data model schema when that is not set), so everything here degrades to
# "no runs" when they do not exist yet. Phenotype names come from the data model schema.

emptyRuns <- function() {
  data.frame(
    runId = integer(0),
    phenotypeId = integer(0),
    phenotypeName = character(0),
    status = character(0),
    timeSubmitted = as.POSIXct(character(0)),
    timeFinished = as.POSIXct(character(0)),
    error = character(0),
    stringsAsFactors = FALSE
  )
}

emptySteps <- function() {
  data.frame(
    runId = integer(0),
    stepIndex = integer(0),
    stepName = character(0),
    status = character(0),
    stringsAsFactors = FALSE
  )
}

# The latest run of each phenotype that is in progress, or that failed within the last day.
getRuns <- function(connection, databaseSchema, progressSchema = databaseSchema) {
  sql <- "SELECT r.run_id,
    r.phenotype_id,
    p.phenotype_name,
    r.status,
    r.time_submitted,
    r.time_finished,
    r.error
  FROM @progress_schema.pegasus_run r
  INNER JOIN (
    SELECT phenotype_id, MAX(run_id) AS run_id
    FROM @progress_schema.pegasus_run
    GROUP BY phenotype_id
  ) latest ON latest.run_id = r.run_id
  INNER JOIN @database_schema.phenotype p
    ON p.phenotype_id = r.phenotype_id
  ORDER BY r.time_submitted DESC;"
  runs <- queryPegasus(connection, databaseSchema, sql, progress_schema = progressSchema)
  cutoff <- Sys.time() - 24 * 3600
  recentFailure <- runs$status == "FAILED" & !is.na(runs$timeFinished) & runs$timeFinished > cutoff
  runs[runs$status %in% c("SUBMITTED", "RUNNING") | recentFailure, , drop = FALSE]
}

getRunSteps <- function(connection, progressSchema, runIds) {
  if (length(runIds) == 0) {
    return(emptySteps())
  }
  sql <- "SELECT run_id, step_index, step_name, status
  FROM @database_schema.pegasus_run_step
  WHERE run_id IN (@run_ids)
  ORDER BY run_id, step_index;"
  # The steps table is only in the progress schema, so that is the schema this query is run against
  queryPegasus(connection, progressSchema, sql, run_ids = as.integer(runIds))
}

isActiveRun <- function(status) {
  status %in% c("SUBMITTED", "RUNNING")
}

stepIcon <- function(status) {
  switch(
    status,
    DONE = icon("circle-check", class = "text-success"),
    RUNNING = tags$span(class = "spinner-border spinner-border-sm text-primary", role = "status"),
    FAILED = icon("circle-xmark", class = "text-danger"),
    icon("circle", class = "text-muted")
  )
}

runCard <- function(run, steps) {
  steps <- steps[steps$runId == run$runId, , drop = FALSE]
  done <- sum(steps$status == "DONE")
  total <- nrow(steps)
  failed <- run$status == "FAILED"
  barClass <- if (failed) "bg-danger" else if (run$status == "SUBMITTED") "bg-secondary" else ""
  percent <- if (total > 0) round(100 * done / total) else 0
  bslib::card(
    bslib::card_header(
      class = "d-flex justify-content-between align-items-center",
      tags$strong(run$phenotypeName),
      tags$span(
        class = paste("badge", if (failed) "text-bg-danger" else if (run$status == "SUBMITTED") "text-bg-warning" else "text-bg-primary"),
        c(SUBMITTED = "Starting", RUNNING = "Running", FAILED = "Failed")[[run$status]]
      )
    ),
    bslib::card_body(
      if (total > 0) {
        tags$div(
          class = "progress mb-2",
          role = "progressbar",
          tags$div(class = paste("progress-bar", barClass), style = sprintf("width: %d%%", percent), sprintf("%d of %d steps", done, total))
        )
      },
      if (total > 0) {
        tags$ul(
          class = "list-unstyled mb-0",
          lapply(seq_len(total), function(i) {
            tags$li(stepIcon(steps$status[i]), HTML("&nbsp;"), steps$stepName[i], class = if (steps$status[i] == "PENDING") "text-muted")
          })
        )
      } else if (!failed) {
        tags$p(class = "text-muted mb-0", "Waiting for the job to start.")
      },
      if (failed && !is.na(run$error)) {
        tags$pre(class = "text-danger small mt-2 mb-0", htmltools::htmlEscape(run$error))
      },
      tags$small(class = "text-muted", "Started ", formatTimestamp(run$timeSubmitted), " UTC")
    )
  )
}

progressUi <- function(id) {
  ns <- NS(id)
  uiOutput(ns("button"), inline = TRUE)
}

# Polls the run tables while the app is open. Whenever a run is in progress the phenotype summary is also
# refreshed, so the status, concept set and cohort counts in the Browse list advance as the backend uploads results.
progressServer <- function(id, connectionPool, databaseSchema, progressSchema, refreshPhenotypes, pollSeconds = 10) {
  moduleServer(id, function(input, output, session) {
    runs <- reactiveVal(emptyRuns())
    steps <- reactiveVal(emptySteps())

    loadRuns <- function() {
      result <- tryCatch(
        withConnection(connectionPool, function(connection) {
          currentRuns <- getRuns(connection, databaseSchema, progressSchema)
          list(runs = currentRuns, steps = getRunSteps(connection, progressSchema, currentRuns$runId))
        }),
        error = function(e) list(runs = emptyRuns(), steps = emptySteps())
      )
      runs(result$runs)
      steps(result$steps)
      result
    }

    observe({
      invalidateLater(pollSeconds * 1000, session)
      result <- loadRuns()
      if (any(isActiveRun(result$runs$status))) {
        isolate(refreshPhenotypes())
      }
    })

    output$button <- renderUI({
      active <- sum(isActiveRun(runs()$status))
      failed <- sum(runs()$status == "FAILED")
      if (active + failed == 0) {
        return(NULL)
      }
      actionButton(
        session$ns("open"),
        label = tagList(
          if (active > 0) tags$span(class = "spinner-border spinner-border-sm", role = "status"),
          if (active > 0) sprintf(" %d job%s running", active, if (active == 1) "" else "s") else sprintf("%d failed job%s", failed, if (failed == 1) "" else "s")
        ),
        class = if (active > 0) "btn-sm btn-outline-primary" else "btn-sm btn-outline-danger"
      )
    })

    output$body <- renderUI({
      current <- runs()
      if (nrow(current) == 0) {
        return(tags$p("No jobs in progress."))
      }
      lapply(seq_len(nrow(current)), function(i) runCard(current[i, , drop = FALSE], steps()))
    })

    observeEvent(input$open, {
      loadRuns()
      showModal(modalDialog(
        title = "Phenotype jobs",
        size = "l",
        easyClose = TRUE,
        footer = modalButton("Close"),
        uiOutput(session$ns("body"))
      ))
    })
  })
}
