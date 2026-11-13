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

function(input, output, session) {
  phenotypes <- reactiveVal(emptyPhenotypeSummary())
  evaluations <- reactiveVal(emptyEvaluations())
  # The landing page being shown (NULL is the Browse list); see routing.R.
  route <- reactiveVal(NULL)
  shortlist <- reactiveVal(integer(0))
  cloneSource <- reactiveVal(NULL)
  launchPreselect <- reactiveVal(NULL)
  createPrefill <- reactiveVal(NULL)
  comparePreselect <- reactiveVal(NULL)

  # Opens the Compare tab with these phenotypes chosen.
  comparePhenotypes <- function(phenotypeIds) {
    comparePreselect(list(ids = phenotypeIds, nonce = as.numeric(Sys.time())))
    bslib::nav_select("mainNav", "Compare", session = session)
  }

  output$shortlistCount <- renderUI({
    if (length(shortlist()) > 0) tags$span(class = "badge text-bg-primary", length(shortlist()))
  })

  # Reloads everything the Browse and Performance tabs show.
  refreshPhenotypes <- function() {
    tryCatch(
      withConnection(connectionPool, function(connection) {
        phenotypes(getPhenotypeSummary(connection, config$databaseSchema))
        evaluations(getEvaluations(connection, config$databaseSchema))
      }),
      error = function(e) {
        showNotification(paste("Unable to load phenotypes:", conditionMessage(e)), type = "error")
      }
    )
  }
  refreshPhenotypes()

  # Shows a landing page (or the Browse list when page is NULL) and, unless the change came from the
  # browser's own back or forward button, adds it to the browser history so that history and the address
  # bar follow along.
  navigate <- createNavigator(
    route,
    updateUrl = function(query) updateQueryString(query, mode = "push", session = session),
    showBrowse = function() bslib::nav_select("mainNav", "Browse", session = session)
  )

  # Switching tabs clears the address of the landing page; returning to Browse restores it.
  observeEvent(input$mainNav, {
    updateQueryString(tabQuery(input$mainNav, route()), mode = "replace", session = session)
  }, ignoreInit = TRUE)

  openPhenotype <- function(phenotypeId) {
    navigate("phenotype", phenotypeId)
  }

  # Links in tables and text (see entityLink in routing.R) report the page they point to.
  observeEvent(input$navigateTo, {
    navigate(input$navigateTo$page, input$navigateTo$id)
  })

  # A shared URL opens its page when the app loads.
  observeEvent(session$clientData$url_search, {
    initial <- parseRoute(session$clientData$url_search)
    if (!is.null(initial)) {
      navigate(initial$page, initial$id, push = FALSE)
    }
  }, once = TRUE)

  # The browser's back and forward buttons report the address they went to.
  observeEvent(input$routeSearch, {
    target <- parseRoute(input$routeSearch)
    navigate(target$page, target$id, push = FALSE)
  })

  # The refinement wizard lives inside the Run Pegasus tab (see launchTabUi); these show it and bring the user back to the
  # form once the refined phenotype is saved.
  showLaunchForm <- function() bslib::nav_select("launchView", "form", session = session)
  showRefinementWizard <- function() {
    bslib::nav_select("launchView", "refine", session = session)
    bslib::nav_select("mainNav", launchTabName, session = session)
  }
  observeEvent(input$launchBack, showLaunchForm())

  # Opens the wizard seeded with an existing phenotype's definition. The nonce makes refining the same phenotype twice
  # restart the wizard.
  refinePhenotype <- function(phenotypeId) {
    data <- phenotypes()
    row <- data[data$phenotypeId == phenotypeId, , drop = FALSE]
    if (nrow(row) != 1) {
      return(invisible(NULL))
    }
    createPrefill(NULL)
    cloneSource(list(
      id = row$phenotypeId,
      name = row$phenotypeName,
      definition = row$clinicalDefinition,
      nonce = as.numeric(Sys.time())
    ))
    showRefinementWizard()
  }

  # The Run Pegasus form can send a name and draft definition to the wizard, which starts refining it straight away.
  refineForLaunch <- function(name, definition) {
    cloneSource(NULL)
    createPrefill(list(name = name, definition = definition, nonce = as.numeric(Sys.time())))
    showRefinementWizard()
  }

  # A saved phenotype goes back to the Run Pegasus form, chosen and ready to run.
  phenotypeSaved <- function(phenotypeId) {
    launchPreselect(list(id = phenotypeId, nonce = as.numeric(Sys.time())))
    showLaunchForm()
    bslib::nav_select("mainNav", launchTabName, session = session)
  }

  browseServer(
    "browse",
    connectionPool = connectionPool,
    databaseSchema = config$databaseSchema,
    progressSchema = config$progressSchema,
    phenotypes = phenotypes,
    refreshPhenotypes = refreshPhenotypes,
    route = route,
    navigate = navigate,
    shortlist = shortlist,
    onRefine = refinePhenotype,
    vocabularyRunner = vocabularyRunner
  )
  performanceServer("performance", evaluations, shortlist = shortlist, onOpenPhenotype = openPhenotype,
                    onCompare = comparePhenotypes,
                    onOpenCohortDefinition = function(cohortDefinitionId) navigate("cohort_definition", cohortDefinitionId))
  compareServer(
    "compare",
    connectionPool = connectionPool,
    databaseSchema = config$databaseSchema,
    phenotypes = phenotypes,
    evaluations = evaluations,
    preselect = comparePreselect,
    onOpenPhenotype = openPhenotype
  )
  conceptsServer(
    "concepts",
    connectionPool = connectionPool,
    databaseSchema = config$databaseSchema,
    vocabularyRunner = vocabularyRunner,
    phenotypes = phenotypes,
    shortlist = shortlist
  )
  shortlistServer(
    "shortlist",
    connectionPool = connectionPool,
    databaseSchema = config$databaseSchema,
    phenotypes = phenotypes,
    evaluations = evaluations,
    shortlist = shortlist,
    onOpenPhenotype = openPhenotype,
    onCompare = comparePhenotypes,
    onOpenCohortDefinition = function(cohortDefinitionId) navigate("cohort_definition", cohortDefinitionId)
  )
  launchServer(
    "launch",
    connectionPool = connectionPool,
    databaseSchema = config$databaseSchema,
    progressSchema = config$progressSchema,
    userName = getUserName(session),
    phenotypes = phenotypes,
    refreshPhenotypes = refreshPhenotypes,
    onRefine = refineForLaunch,
    preselect = launchPreselect,
    llmConfig = config$llm
  )
  createServer(
    "create",
    connectionPool = connectionPool,
    databaseSchema = config$databaseSchema,
    llmConfig = config$llm,
    systemPrompt = systemPrompt,
    userName = getUserName(session),
    phenotypes = phenotypes,
    refreshPhenotypes = refreshPhenotypes,
    cloneSource = cloneSource,
    onSaved = phenotypeSaved,
    prefill = createPrefill
  )
}
