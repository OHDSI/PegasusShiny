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
# limitations under the License.

# Run Pegasus (Beta): requests a run of the backend pipeline with explicit parameters. The app writes a row to
# pegasus_run_request (see sql/CreateProgressTables.sql) and the backend's queue poller turns it into a run, which then
# shows up in the progress button on the Browse tab. Only parameters the backend accepts are offered.

# The steps of the backend pipeline, in order. Keep in step with Pegasus::createCohortDefinitionsAndEvaluateSteps; the
# summary panel lists them so users can see what a launch will do.
launchPipelineSteps <- c(
  "Phenotype metadata",
  "Concept set targets",
  "Concept set target definitions",
  "Concept sets",
  "Concept set person counts",
  "Keeper reference cohorts",
  "Cohort definitions (MonoFlow agent)",
  "Cohort definitions (templates)",
  "Evaluation"
)

# The name of the tab, which other tabs use to send the user back to it.
launchTabName <- "Run Pegasus (Beta)"

launchIntents <- c("New phenotype" = "NEW_PHENOTYPE", "Re-run an existing phenotype" = "RERUN")

# Options users will want that the backend does not take yet. They are shown disabled so the layout stays put when
# the backend learns them.
launchUnavailableOptions <- c(
  "Skip the MonoFlow cohort definitions",
  "Skip the template cohort definitions",
  "Regenerate concept sets instead of reusing existing ones",
  "Add my own cohort definitions",
  "Choose the standard concept sets to use",
  "Evaluation types other than Keeper"
)

maxLaunchCores <- 16L

blankToNa <- function(x) {
  if (is.null(x) || length(x) == 0 || is.na(x) || !nzchar(trimws(x))) NA_character_ else trimws(x)
}

# What has to be right before a run can be launched, one row per check (ok, and what is wrong when it is not).
launchChecklist <- function(intent, name, description, phenotypeId, databaseIds, maxCores, existingNames,
                            hasActiveRun = FALSE, signedIn = TRUE) {
  check <- function(item, ok, detail = "") data.frame(item = item, ok = isTRUE(ok), detail = if (isTRUE(ok)) "" else detail)
  name <- trimws(if (is.null(name)) "" else name)
  description <- trimws(if (is.null(description)) "" else description)
  phenotypeId <- if (is.null(phenotypeId) || length(phenotypeId) == 0) NA_integer_ else phenotypeId
  maxCores <- if (is.null(maxCores) || length(maxCores) == 0) NA_real_ else maxCores
  rows <- list(check("Signed in", signedIn, "You are not logged in."))
  if (identical(intent, "NEW_PHENOTYPE") && !is.na(phenotypeId)) {
    # The phenotype was already saved by the refinement wizard, so only the run settings remain.
    rows <- c(rows, list(check("Phenotype saved", TRUE)))
  } else if (identical(intent, "NEW_PHENOTYPE")) {
    nameOk <- nzchar(name) && !phenotypeNameExists(name, existingNames)
    rows <- c(rows, list(
      check("Phenotype name", nameOk, if (nzchar(name)) "A phenotype with this name already exists." else "Enter a name."),
      check("Clinical definition", nzchar(description), "Enter the clinical definition.")
    ))
  } else {
    rows <- c(rows, list(
      check("Phenotype chosen", !is.na(phenotypeId), "Choose the phenotype to re-run."),
      check("No run in progress", !hasActiveRun, "This phenotype already has a run waiting or in progress.")
    ))
  }
  coresOk <- is.na(maxCores) || (maxCores >= 1 && maxCores <= maxLaunchCores && maxCores == round(maxCores))
  rows <- c(rows, list(
    check("Databases", length(databaseIds) > 0, "Choose at least one database."),
    check("Cores", coresOk, sprintf("Use a whole number from 1 to %d, or leave it empty for the default.", maxLaunchCores))
  ))
  do.call(rbind, rows)
}

# One row for pegasus_run_request. Empty optional settings stay NA, which the backend reads as "use the default".
buildRunRequest <- function(runRequestId, intent, phenotypeId, databaseIds, llmModel = NULL, llmFrontierModel = NULL,
                            maxCores = NULL, requestedBy, timeRequested = Sys.time()) {
  attr(timeRequested, "tzone") <- "UTC"
  data.frame(
    runRequestId = as.integer(runRequestId),
    requestType = intent,
    phenotypeId = as.integer(phenotypeId),
    databaseIds = as.character(jsonlite::toJSON(as.integer(databaseIds), auto_unbox = FALSE)),
    llmModel = blankToNa(llmModel),
    llmFrontierModel = blankToNa(llmFrontierModel),
    maxCores = if (is.null(maxCores) || length(maxCores) == 0 || is.na(maxCores)) NA_integer_ else as.integer(maxCores),
    requestOptions = NA_character_,
    requestedBy = requestedBy,
    timeRequested = timeRequested,
    status = "REQUESTED",
    runId = NA_integer_,
    message = NA_character_,
    stringsAsFactors = FALSE
  )
}

# The database ids in a request's database_ids column (a JSON array of database_meta_data ids), as one text per request
# with the databases' labels. An id that is not in the databases table is shown as "#id".
requestDatabaseLabels <- function(json, databases) {
  vapply(json, function(x) {
    ids <- tryCatch(as.integer(jsonlite::fromJSON(x)), error = function(e) integer(0))
    labels <- databases$databaseLabel[match(ids, databases$databaseId)]
    paste(ifelse(is.na(labels), paste0("#", ids), labels), collapse = ", ")
  }, "", USE.NAMES = FALSE)
}

# Saves a request for a phenotype that exists, and returns its id. A new phenotype without an id is created first (draft,
# so it shows in Browse as queued), which also reports a name that is already taken before anything is requested. A new
# phenotype that was already saved (by the refinement wizard) is passed with its id.
submitRunRequest <- function(connection, databaseSchema, progressSchema, intent, phenotypeId = NA_integer_, name = "",
                             description = "", databaseIds, llmModel = NULL, llmFrontierModel = NULL, maxCores = NULL,
                             requestedBy) {
  if (length(databaseIds) == 0) {
    stop("Choose at least one database.")
  }
  if (identical(intent, "NEW_PHENOTYPE") && is.na(phenotypeId)) {
    phenotypeId <- savePhenotype(connection, databaseSchema, name, description, requestedBy)
  } else if (is.na(phenotypeId)) {
    stop("Choose the phenotype to re-run.")
  }
  runRequestId <- getNextId(connection, progressSchema, "pegasus_run_request", "run_request_id")
  request <- buildRunRequest(
    runRequestId, intent, phenotypeId, databaseIds, llmModel, llmFrontierModel, maxCores, requestedBy
  )
  insertPegasusRows(connection, progressSchema, "pegasus_run_request", request)
  list(runRequestId = runRequestId, phenotypeId = as.integer(phenotypeId))
}

emptyRunRequests <- function() {
  data.frame(
    runRequestId = integer(0), requestType = character(0), phenotypeId = integer(0), phenotypeName = character(0),
    databaseIds = character(0), requestedBy = character(0), timeRequested = as.POSIXct(character(0)),
    status = character(0), runId = integer(0), runStatus = character(0), message = character(0),
    stringsAsFactors = FALSE
  )
}

getRunRequests <- function(connection, databaseSchema, progressSchema, limit = 200) {
  sql <- "SELECT TOP @limit r.run_request_id,
    r.request_type,
    r.phenotype_id,
    p.phenotype_name,
    r.database_ids,
    r.requested_by,
    r.time_requested,
    r.status,
    r.run_id,
    ru.status AS run_status,
    r.message
  FROM @progress_schema.pegasus_run_request r
  INNER JOIN @database_schema.phenotype p
    ON p.phenotype_id = r.phenotype_id
  LEFT JOIN @progress_schema.pegasus_run ru
    ON ru.run_id = r.run_id
  ORDER BY r.time_requested DESC, r.run_request_id DESC;"
  queryPegasus(connection, databaseSchema, sql, progress_schema = progressSchema, limit = as.integer(limit))
}

# Where a request is in its life, for the table.
requestStatusLabel <- function(status, runStatus) {
  label <- ifelse(
    status == "REQUESTED", "Waiting for the backend",
    ifelse(status == "REJECTED", "Rejected", ifelse(is.na(runStatus), "Started", tools::toTitleCase(tolower(runStatus))))
  )
  badge <- ifelse(
    status == "REJECTED" | (!is.na(runStatus) & runStatus == "FAILED"), "text-bg-danger",
    ifelse(!is.na(runStatus) & runStatus == "DONE", "text-bg-success", "text-bg-warning")
  )
  sprintf('<span class="badge %s">%s</span>', badge, label)
}

launchUi <- function(id) {
  ns <- NS(id)
  tagList(
    tags$div(
      class = "alert alert-warning py-2",
      tags$strong("Beta. "),
      "Launching writes a request that the backend picks up (it checks every couple of minutes). ",
      "Only the options the backend accepts today are available."
    ),
    bslib::layout_columns(
      col_widths = c(8, 4),
      fill = FALSE,
      tags$div(
        class = "d-flex flex-column gap-3",
        bslib::card(
          fill = FALSE,
          bslib::card_header("1. What do you want to run?"),
          radioButtons(ns("intent"), NULL, choices = launchIntents, selected = "NEW_PHENOTYPE")
        ),
        bslib::card(
          fill = FALSE,
          bslib::card_header("2. Phenotype"),
          # Like the New phenotype tab: a name and an initial definition, which the assistant can refine.
          conditionalPanel(
            condition = sprintf("input['%s'] == 'NEW_PHENOTYPE' && !output['%s']", ns("intent"), ns("hasSaved")),
            tags$div(
              class = "d-flex justify-content-between align-items-center",
              tags$span(class = "text-muted small", "Refine the definition with the assistant, or run it as written."),
              uiOutput(ns("modelBadge"), inline = TRUE)
            ),
            textInput(ns("name"), "Phenotype name", width = "100%"),
            textAreaInput(ns("description"), "Clinical definition (initial definition)", rows = 8, width = "100%"),
            uiOutput(ns("similarNames")),
            actionButton(ns("refine"), "Refine description", icon = icon("wand-magic-sparkles"), class = "btn-outline-primary")
          ),
          conditionalPanel(
            condition = sprintf("input['%s'] == 'NEW_PHENOTYPE' && output['%s']", ns("intent"), ns("hasSaved")),
            uiOutput(ns("savedSummary"))
          ),
          conditionalPanel(
            condition = sprintf("input['%s'] == 'RERUN'", ns("intent")),
            shinyWidgets::pickerInput(
              ns("phenotype"), "Phenotype to re-run", choices = c("Choose a phenotype" = ""), multiple = FALSE,
              width = "100%", options = shinyWidgets::pickerOptions(container = "body", liveSearch = TRUE)
            ),
            uiOutput(ns("phenotypeSummary"))
          )
        ),
        bslib::card(
          fill = FALSE,
          bslib::card_header("3. Databases"),
          shinyWidgets::pickerInput(
            ns("databases"), "Run against", choices = character(0), multiple = TRUE, width = "100%",
            options = shinyWidgets::pickerOptions(
              container = "body", actionsBox = TRUE, selectedTextFormat = "count > 2",
              noneSelectedText = "Choose one or more databases"
            )
          ),
          uiOutput(ns("databasesNote"))
        ),
        bslib::accordion(
          open = FALSE,
          bslib::accordion_panel(
            "4. Advanced settings",
            helpText("Leave these empty to use the backend's defaults."),
            textInput(ns("llmModel"), "Language model", placeholder = "Backend default", width = "100%"),
            textInput(ns("llmFrontierModel"), "Frontier model (cohort definition agent)", placeholder = "Backend default", width = "100%"),
            numericInput(ns("maxCores"), "Maximum cores", value = NA, min = 1, max = maxLaunchCores, step = 1, width = "50%"),
            tags$h6(class = "mt-3", "Not available yet"),
            helpText("The backend does not take these options yet."),
            lapply(launchUnavailableOptions, function(label) {
              tags$div(
                class = "form-check text-muted",
                tags$input(class = "form-check-input", type = "checkbox", disabled = NA),
                tags$label(class = "form-check-label", label)
              )
            })
          )
        )
      ),
      bslib::card(
        fill = FALSE,
        style = "position: sticky; top: 1rem;",
        bslib::card_header("Run summary"),
        uiOutput(ns("summary")),
        bslib::card_footer(
          class = "d-flex justify-content-between align-items-center",
          uiOutput(ns("userNote")),
          uiOutput(ns("launchButton"))
        )
      )
    ),
    bslib::card(
      full_screen = TRUE,
      min_height = "420px",
      bslib::card_header(
        class = "d-flex justify-content-between align-items-center",
        "Launches",
        tags$div(
          class = "d-flex gap-3 align-items-center",
          checkboxInput(ns("onlyMine"), "Only my launches", value = FALSE),
          actionButton(ns("refreshRequests"), "Refresh", icon = icon("rotate"), class = "btn-sm")
        )
      ),
      DT::DTOutput(ns("requests"))
    )
  )
}

# onRefine(name, definition) sends the user to the New phenotype tab, which comes back with preselect = list(id, nonce)
# once the refined phenotype is saved.
launchServer <- function(id, connectionPool, databaseSchema, progressSchema, userName, phenotypes, refreshPhenotypes,
                         onRefine = function(name, definition) NULL, preselect = reactiveVal(NULL),
                         llmConfig = NULL) {
  moduleServer(id, function(input, output, session) {
    requestsVersion <- reactiveVal(0)
    signedIn <- !is.null(userName)
    # The phenotype saved by the refinement wizard, waiting to be run (NA when there is none).
    savedPhenotypeId <- reactiveVal(NA_integer_)

    # A flag the page reads to switch between the form and the summary of the saved phenotype ("" is false in the browser)
    output$hasSaved <- renderText(if (is.na(savedPhenotypeId())) "" else "yes")
    outputOptions(output, "hasSaved", suspendWhenHidden = FALSE)

    output$modelBadge <- renderUI({
      if (is.null(llmConfig)) return(NULL)
      tags$span(
        class = "badge text-bg-light border fw-normal", title = "The language model used for the refinement",
        icon("microchip"), " ", llmModelLabel(llmConfig)
      )
    })

    observeEvent(preselect(), {
      id <- suppressWarnings(as.integer(preselect()$id))
      if (length(id) == 1 && !is.na(id)) {
        savedPhenotypeId(id)
        updateRadioButtons(session, "intent", selected = "NEW_PHENOTYPE")
        updateTextInput(session, "name", value = "")
        updateTextAreaInput(session, "description", value = "")
      }
    }, ignoreNULL = TRUE)

    observeEvent(input$refine, {
      name <- trimws(input$name)
      if (!nzchar(name)) {
        showNotification("Please enter a phenotype name.", type = "warning")
        return()
      }
      if (phenotypeNameExists(name, phenotypes()$phenotypeName)) {
        showNotification(sprintf("A phenotype named '%s' already exists.", name), type = "error")
        return()
      }
      onRefine(name, input$description)
    })

    observeEvent(input$clearSaved, savedPhenotypeId(NA_integer_))

    output$savedSummary <- renderUI({
      id <- savedPhenotypeId()
      row <- phenotypes()[phenotypes()$phenotypeId %in% id, , drop = FALSE]
      tags$div(
        class = "alert alert-success",
        tags$div(
          class = "d-flex justify-content-between align-items-start",
          tags$span(icon("circle-check"), " Saved ", tags$strong(if (nrow(row) == 1) row$phenotypeName else paste("phenotype", id)),
                    " from the refinement. It will be run as it is saved."),
          actionButton(session$ns("clearSaved"), "Use something else", class = "btn-sm btn-outline-secondary")
        ),
        if (nrow(row) == 1) tags$p(class = "small mt-2 mb-0", style = "white-space: pre-wrap;", row$clinicalDefinition)
      )
    })

    output$userNote <- renderUI({
      if (signedIn) tags$span(class = "text-muted small", paste("Requested as:", userName)) else
        tags$span(class = "text-danger small", "You are not logged in. Launching is disabled.")
    })

    # The databases the data model knows (database_meta_data), which are the ones a run has been made against before.
    databases <- reactive({
      requestsVersion()
      tryCatch(
        withConnection(connectionPool, function(connection) getDatabases(connection, databaseSchema)),
        error = function(e) {
          logEvent("databases could not be read: ", conditionMessage(e))
          NULL
        }
      )
    })

    observe({
      data <- req(databases())
      shinyWidgets::updatePickerInput(
        session, "databases",
        choices = stats::setNames(data$databaseId, sprintf("%s - %s", data$databaseLabel, data$cdmSourceName)),
        selected = isolate(input$databases)
      )
    })

    output$databasesNote <- renderUI({
      if (is.null(databases()) || nrow(databases()) == 0) {
        tags$div(
          class = "alert alert-info py-2 mb-0",
          "No databases are recorded in the data model yet (database_meta_data is empty or could not be read)."
        )
      }
    })

    phenotypeChoices <- reactive({
      data <- phenotypes()
      data <- data[order(data$phenotypeName), , drop = FALSE]
      c("Choose a phenotype" = "", stats::setNames(as.character(data$phenotypeId), data$phenotypeName))
    })
    observe({
      shinyWidgets::updatePickerInput(session, "phenotype", choices = phenotypeChoices(), selected = isolate(input$phenotype))
    })

    selectedPhenotypeId <- reactive({
      id <- suppressWarnings(as.integer(input$phenotype))
      if (length(id) == 1 && !is.na(id) && id %in% phenotypes()$phenotypeId) id else NA_integer_
    })

    output$phenotypeSummary <- renderUI({
      id <- selectedPhenotypeId()
      if (is.na(id)) return(NULL)
      row <- phenotypes()[phenotypes()$phenotypeId == id, , drop = FALSE]
      tags$div(
        class = "small",
        tags$p(class = "mb-1 text-muted", sprintf("Status: %s", row$status)),
        tags$p(class = "mb-0", style = "white-space: pre-wrap;", row$clinicalDefinition)
      )
    })

    output$similarNames <- renderUI({
      name <- trimws(input$name)
      if (!nzchar(name)) return(NULL)
      existing <- phenotypes()$phenotypeName
      if (phenotypeNameExists(name, existing)) {
        return(tags$p(class = "text-danger small", "A phenotype with this name already exists."))
      }
      similar <- findSimilarNames(name, existing)
      if (length(similar) > 0) {
        tags$p(class = "text-warning small", "Similar existing names: ", paste(similar, collapse = ", "))
      }
    })

    requests <- reactive({
      requestsVersion()
      tryCatch(
        withConnection(connectionPool, function(connection) getRunRequests(connection, databaseSchema, progressSchema)),
        error = function(e) {
          logEvent("run requests could not be read: ", conditionMessage(e))
          emptyRunRequests()
        }
      )
    })

    # A phenotype that already has a request waiting, or a run in progress, should not get another.
    hasActiveRun <- reactive({
      id <- selectedPhenotypeId()
      if (is.na(id) || !identical(input$intent, "RERUN")) return(FALSE)
      waiting <- any(requests()$phenotypeId == id & requests()$status == "REQUESTED")
      running <- tryCatch(
        withConnection(connectionPool, function(connection) {
          runs <- getRuns(connection, databaseSchema, progressSchema)
          any(runs$phenotypeId == id & isActiveRun(runs$status))
        }),
        error = function(e) FALSE
      )
      waiting || running
    })

    # The phenotype this launch is about: the chosen one for a re-run, the saved one for a refined new phenotype.
    launchPhenotypeId <- reactive({
      if (identical(input$intent, "NEW_PHENOTYPE")) savedPhenotypeId() else selectedPhenotypeId()
    })

    checklist <- reactive({
      launchChecklist(
        intent = input$intent, name = input$name, description = input$description, phenotypeId = launchPhenotypeId(),
        databaseIds = input$databases, maxCores = input$maxCores, existingNames = phenotypes()$phenotypeName,
        hasActiveRun = hasActiveRun(), signedIn = signedIn
      )
    })

    output$summary <- renderUI({
      checks <- checklist()
      steps <- tags$ol(class = "small mb-0 ps-3", lapply(launchPipelineSteps, tags$li))
      setting <- function(label, value) {
        tags$tr(tags$td(class = "text-muted pe-3", label), tags$td(if (is.na(value)) tags$em("Backend default") else value))
      }
      what <- if (identical(input$intent, "RERUN") || !is.na(savedPhenotypeId())) {
        id <- launchPhenotypeId()
        if (is.na(id)) NA_character_ else phenotypes()$phenotypeName[match(id, phenotypes()$phenotypeId)]
      } else {
        blankToNa(input$name)
      }
      tagList(
        tags$ul(
          class = "list-unstyled mb-3",
          lapply(seq_len(nrow(checks)), function(i) {
            tags$li(
              if (checks$ok[i]) icon("circle-check", class = "text-success") else icon("circle", class = "text-muted"),
              " ", checks$item[i],
              if (!checks$ok[i] && nzchar(checks$detail[i])) tags$div(class = "small text-muted ms-4", checks$detail[i])
            )
          })
        ),
        tags$table(
          class = "small mb-3",
          tags$tbody(
            setting("Phenotype", what),
            setting("Databases", if (length(input$databases) == 0) NA_character_ else paste(databases()$databaseLabel[match(as.integer(input$databases), databases()$databaseId)], collapse = ", ")),
            setting("Language model", blankToNa(input$llmModel)),
            setting("Frontier model", blankToNa(input$llmFrontierModel)),
            setting("Maximum cores", if (is.na(input$maxCores)) NA_character_ else as.character(input$maxCores))
          )
        ),
        tags$h6("Pipeline steps"),
        steps,
        tags$p(class = "small text-muted mt-2", "Every step runs; steps whose results already exist are reused by the backend.")
      )
    })

    output$launchButton <- renderUI({
      ready <- all(checklist()$ok)
      actionButton(
        session$ns("launch"), "Launch", icon = icon("rocket"), class = "btn-success",
        disabled = if (ready) NULL else NA
      )
    })

    observeEvent(input$launch, {
      if (!all(checklist()$ok)) {
        return(invisible(NULL))
      }
      outcome <- tryCatch(
        withConnection(connectionPool, function(connection) {
          submitRunRequest(
            connection, databaseSchema, progressSchema,
            intent = input$intent, phenotypeId = launchPhenotypeId(), name = input$name, description = input$description,
            databaseIds = input$databases, llmModel = input$llmModel, llmFrontierModel = input$llmFrontierModel,
            maxCores = input$maxCores, requestedBy = userName
          )
        }),
        error = function(e) {
          showNotification(paste("Unable to launch:", conditionMessage(e)), type = "error", duration = NULL)
          NULL
        }
      )
      if (is.null(outcome)) {
        return(invisible(NULL))
      }
      showNotification("Launch requested. The backend will pick it up shortly.", type = "message")
      if (identical(input$intent, "NEW_PHENOTYPE")) {
        savedPhenotypeId(NA_integer_)
        updateTextInput(session, "name", value = "")
        updateTextAreaInput(session, "description", value = "")
      }
      requestsVersion(requestsVersion() + 1)
      refreshPhenotypes()
    })

    observeEvent(input$refreshRequests, requestsVersion(requestsVersion() + 1))

    output$requests <- DT::renderDT({
      data <- requests()
      if (isTRUE(input$onlyMine) && signedIn) {
        data <- data[data$requestedBy == userName, , drop = FALSE]
      }
      filterableTable(
        data.frame(
          Requested = formatTimestamp(data$timeRequested),
          By = htmltools::htmlEscape(data$requestedBy),
          Type = ifelse(data$requestType == "NEW_PHENOTYPE", "New phenotype", "Re-run"),
          Phenotype = entityLink("phenotype", data$phenotypeId, data$phenotypeName),
          Databases = htmltools::htmlEscape(requestDatabaseLabels(data$databaseIds, databases())),
          Status = requestStatusLabel(data$status, data$runStatus),
          Message = htmltools::htmlEscape(ifelse(is.na(data$message), "", data$message)),
          check.names = FALSE
        ),
        escape = FALSE,
        rownames = FALSE,
        selection = "none",
        options = list(
          pageLength = 10,
          order = list(list(0, "desc")),
          language = list(emptyTable = "No launches yet.")
        )
      )
    })
  })
}
