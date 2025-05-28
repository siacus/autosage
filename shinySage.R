library(shiny)
library(httr)
library(jsonlite)
library(stringr)
library(stringdist)

# Load available categories
subjects <- fromJSON("categories.json")

# Define helper functions (same as before)
create_prompt <- function(title, description) {
  formatted_subjects <- paste0("['", paste(subjects, collapse = "', '"), "']")
  sprintf(
    "<s>[INST] Here are Title and Description of a dataset. Title :'%s' Description:'%s'. And this are subject categories: %s. Please return only a json list of at most 3 elements corresponding to the text labels:[/INST]",
    title, description, formatted_subjects
  )
}

get_responses <- function(answer) {
  bracket_start <- regexpr("\\[\\[?\\s*['\"]", answer)
  if (bracket_start == -1) return(character(0))
  substr_answer <- substr(answer, bracket_start, nchar(answer))
  if (str_count(substr_answer, "\\[") > str_count(substr_answer, "\\]")) {
    substr_answer <- paste0(substr_answer, "]")
  }
  matches <- str_match_all(substr_answer, "'([^']+)'|\"([^\"]+)\"")[[1]]
  labels <- na.omit(c(matches[,2], matches[,3]))
  unquoted_tail <- str_match(substr_answer, ".*,\\s*['\"]?([^'\"\\]]+?)\\s*(\\]|$)")[,2]
  if (!is.na(unquoted_tail) && nchar(unquoted_tail) > 3 && !unquoted_tail %in% labels) {
    labels <- c(labels, unquoted_tail)
  }
  unique(labels)
}

match_to_categories <- function(labels, max_dist = 0.7) {
  distance_methods <- c("jw", "cosine", "osa")
  results <- lapply(labels, function(label) {
    best_distance <- Inf
    best_subject <- NULL
    for (method in distance_methods) {
      dists <- stringdist(tolower(label), tolower(subjects), method = method)
      if (min(dists) < best_distance) {
        best_distance <- min(dists)
        best_subject <- subjects[which.min(dists)]
      }
    }
    if (best_distance <= max_dist) return(best_subject) else return(NULL)
  })
  unique(na.omit(unlist(results)))
}

create_keyword_prompt <- function(title, description, subject) {
  paste0(
    "<|begin_of_text|><|start_header_id|>system<|end_header_id|> You are a research archivist expert in dataset metadata. Answer the question truthfully. <|eot_id|><|start_header_id|>user<|end_header_id|> Here is the Description of a dataset. Description:'",
    description,
    "'. Please return only a json list of at most 3 Keywords corresponding to the Title, Description and Subject. Title: '",
    title, "'. Subject: '", subject, "'.<|eot_id|><|start_header_id|>assistant<|end_header_id|> Answer :"
  )
}

extract_keywords <- function(answer) {
  match <- str_match(answer, "\\[\\s*(['\"].+?['\"](?:\\s*,\\s*['\"].+?['\"])*?)\\s*\\]")
  if (is.na(match[1,2])) return(character(0))
  items <- strsplit(match[1,2], "\\s*,\\s*")[[1]]
  stringr::str_replace_all(items, "^['\"]|['\"]$", "")
}

query_categories <- function(title, abstract) {
  prompt <- create_prompt(title, abstract)
  payload <- list(model = "llama", messages = list(list(role = "user", content = prompt)), temperature = 0.0, max_tokens = 50)
  res <- POST("http://140.247.120.209:8081/v1/chat/completions", body = toJSON(payload, auto_unbox = TRUE), encode = "json")
  parsed <- fromJSON(content(res, as = "text", encoding = "UTF-8"))
  get_responses(parsed$choices$message$content)
}

query_keywords <- function(title, abstract, subject) {
  prompt <- create_keyword_prompt(title, abstract, subject)
  payload <- list(model = "llama", messages = list(list(role = "user", content = prompt)), temperature = 0.0, max_tokens = 128)
  res <- POST("http://140.247.120.209:8082/v1/chat/completions", body = toJSON(payload, auto_unbox = TRUE), encode = "json")
  parsed <- fromJSON(content(res, as = "text", encoding = "UTF-8"))
  extract_keywords(parsed$choices$message$content)
}

ui <- fluidPage(
  tags$head(tags$style(HTML(
    ".spinner-border { margin-top: 10px; width: 1.5rem; height: 1.5rem; vertical-align: middle; float: right; }"
  ))),
  titlePanel("Subject & Keyword Suggester"),
  sidebarLayout(
    sidebarPanel(
      textInput("title", "Title"),
      textAreaInput("abstract", "Abstract", height = "200px"),
      fluidRow(
        column(8, actionButton("generate", "Suggest Subject Categories")),
        column(4, uiOutput("loading_spinner"))
      ),
      selectInput("add_category", "Add Subject Category", choices = subjects),
      fluidRow(
        column(8, actionButton("add_button", "Add and Suggest Keywords")),
        column(4, uiOutput("add_spinner"))
      )
    ),
    mainPanel(
      h4("Suggested Categories"),
      uiOutput("category_tags"),
      h4("Keywords by Category"),
      uiOutput("keyword_lists")
    )
  )
)

server <- function(input, output, session) {
  categories <- reactiveVal()
  keywords <- reactiveValues()
  loading <- reactiveVal(FALSE)
  loadingAdd <- reactiveVal(FALSE)

  output$loading_spinner <- renderUI({
    if (loading()) tags$span(
      class = "spinner-border text-primary", 
      role = "status", 
      `aria-hidden` = "true",
      tags$span(class = "visually-hidden", "Loading...")
    )
  })

  output$add_spinner <- renderUI({
    if (loadingAdd()) tags$span(
      class = "spinner-border text-info", 
      role = "status", 
      `aria-hidden` = "true",
      tags$span(class = "visually-hidden", "Loading...")
    )
  })

  observeEvent(input$generate, {
    withProgress(message = "Generating suggestions...", value = 0, {
      loading(TRUE)
      cats <- match_to_categories(query_categories(input$title, input$abstract))
      incProgress(0.3)
      categories(cats)
      for (i in seq_along(cats)) {
        keywords[[cats[i]]] <- query_keywords(input$title, input$abstract, cats[i])
        incProgress(0.7 / length(cats))
      }
      loading(FALSE)
    })
  })

  observeEvent(input$add_button, {
    withProgress(message = "Adding new category...", value = 0, {
      cat <- input$add_category
      if (!(cat %in% categories())) {
        loadingAdd(TRUE)
        categories(c(categories(), cat))
        incProgress(0.5)
        keywords[[cat]] <- query_keywords(input$title, input$abstract, cat)
        incProgress(1)
        loadingAdd(FALSE)
      }
    })
  })

  output$keyword_lists <- renderUI({
    req(categories())
    do.call(tagList, lapply(categories(), function(cat) {
      tagList(
        tags$h5(cat),
        tags$ul(
          lapply(seq_along(keywords[[cat]]), function(i) {
            keyword <- keywords[[cat]][i]
            remove_id <- paste0("remove_kw_", cat, "_", i)
            observeEvent(input[[remove_id]], {
              isolate({
                current <- keywords[[cat]]
                if (i <= length(current)) {
                  keywords[[cat]] <- current[-i]
                }
              })
            })
            tags$li(keyword, actionButton(remove_id, "x", class = "btn-xs btn-outline-danger"))
          })
        )
      )
    }))
  })
}

shinyApp(ui, server)
