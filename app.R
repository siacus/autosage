library(shiny)
library(shinydashboard)
library(httr)
library(jsonlite)
library(stringr)
library(stringdist)

subjects <- fromJSON("categories.json")

create_prompt <- function(title, description) {
  formatted_subjects <- paste0("['", paste(subjects, collapse = "', '"), "]")
  sprintf(
    "<s>[INST] Here are Title and Description of a dataset. Title :' %s ' Description:' %s '. And this are subject categories: %s. Please return only a json list of at most 3 elements corresponding to the text labels:",
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

query_categories <- function(title, description) {
  prompt <- create_prompt(title, description)
  payload <- list(model = "llama", messages = list(list(role = "user", content = prompt)), temperature = 0.0, max_tokens = 50)
  res <- POST("http://140.247.120.209:8081/v1/chat/completions", body = toJSON(payload, auto_unbox = TRUE), encode = "json")
  parsed <- fromJSON(content(res, as = "text", encoding = "UTF-8"))
  content <- parsed$choices$message[1,"content"]
  get_responses(content)
}

query_keywords <- function(title, description, subject) {
  prompt <- create_keyword_prompt(title, description, subject)
  payload <- list(model = "llama", messages = list(list(role = "user", content = prompt)), temperature = 0.0, max_tokens = 128)
  res <- POST("http://140.247.120.209:8082/v1/chat/completions", body = toJSON(payload, auto_unbox = TRUE), encode = "json")
  parsed <- fromJSON(content(res, as = "text", encoding = "UTF-8"))
  extract_keywords(parsed$choices$message$content)
}


get_dataset_metadata <- function(doi, base_url = "https://dataverse.harvard.edu") {
  doi <- sub(".*(10\\.[0-9]+/[^\\s]+)", "\\1", doi)
  url <- paste0(base_url, "/api/datasets/:persistentId")
  res <- httr::GET(url, query = list(persistentId = paste0("doi:", doi)))
  if (res$status_code != 200) stop("Failed to fetch dataset info.")
  data <- jsonlite::fromJSON(content(res, as = "text", encoding = "UTF-8"))
  fields <- data$data$latestVersion$metadataBlocks$citation$fields

  title <- tryCatch({ fields$value[fields$typeName == "title"][[1]] }, error = function(e) NA)
  description <- tryCatch({
    desc_df <- fields$value[[which(fields$typeName == "dsDescription")]]
    desc_df$dsDescriptionValue$value[1]
  }, error = function(e) NA)
  subjects <- tryCatch({ fields$value[fields$typeName == "subject"][[1]] }, error = function(e) character(0))
  keywords <- tryCatch({
    kw_block <- fields$value[[which(fields$typeName == "keyword")]]
    kw_block$keywordValue$value
  }, error = function(e) character(0))

  list(title = title, description = description, subjects = subjects, keywords = keywords)
}

ui <- dashboardPage(
   dashboardHeader(
    # You can leave the default title empty or use it for the collapsed sidebar
    title = "AI Helper",
    tags$li(class = "dropdown",
            style = "padding: 15px;",
            tags$h4("Dataset Metadata Creator", style = "margin: 0; color: white;")) 
  ),dashboardSidebar(
    sidebarMenu(
      menuItem("Controls", tabName = "controls", icon = icon("sliders-h")),
      selectInput("add_category", "Add Subject Category", choices = subjects),
      actionButton("add_button", "Add and Suggest Keywords"),
      tags$hr(),  
      selectInput("selected_category", "Select Category to Add Keyword", choices = subjects),
      textInput("manual_keyword", "Manual Keyword"),
      actionButton("add_keyword", "Add Keyword(s)"),
      tags$hr(),  
      textInput("doi_input", "Enter Dataset DOI"),
      actionButton("grab_doi", "Grab Data"),
      tags$hr(),
      actionButton("regen_llm", "Suggest More Metadata"),
      actionButton("reset_all", "Reset Data"),
     tags$hr(),
      tags$p("© 2025 S.M. Iacus (Shiny App, AI Model), B. Treacy (AI Model)",
        style = "text-align: center; font-size: 12px; color: #aaa; margin: 10px auto; padding: 0 10px; word-wrap: break-word; white-space: normal;")
    )
  ),
  dashboardBody(
    tags$head(tags$style(HTML(".subject-badge {background-color: #6c757d; color: white; font-size: 1.1em; padding: 7px 12px; border-radius: 20px; margin: 4px; display: inline-block;} .keyword-badge {background-color: #e9ecef; border: 1px solid #6c757d; font-size: 0.85em; padding: 4px 8px; border-radius: 12px; margin: 3px; display: inline-block;} .keyword-remove-btn {margin-left: 6px; font-size: 0.75em; vertical-align: middle;}"))),
    fluidRow(
      box(width = 12, title = "Input Data", status = "primary", solidHeader = TRUE,
          textInput("title", "Dataset Title", width = "100%"),
          textAreaInput("description", "Dataset Description", height = "200px", width = "100%"),
          actionButton("generate", "Suggest Subject Categories")
      )
    ),
    fluidRow(
      box(width = 12, title = "Suggested Subject Categories", status = "primary", solidHeader = TRUE, uiOutput("category_tags"))
    ),
    fluidRow(
      box(width = 12, title = "Keywords by Category", status = "info", solidHeader = TRUE, uiOutput("keyword_lists"))
    )
  )
)

server <- function(input, output, session) {
  categories <- reactiveVal()
  keywords <- reactiveValues()
  normalize_keywords <- function(x) {
    tolower(trimws(x))
  }
  format_keywords <- function(x) {
    tools::toTitleCase(trimws(x))
  }

  observeEvent(input$generate, {
    cats <- NULL
    withProgress(message = "Generating suggestions...", value = 0, {
      cats <- match_to_categories(query_categories(input$title, input$description))
      incProgress(0.3)
      categories(cats)
      for (i in seq_along(cats)) {
        keywords[[cats[i]]] <- query_keywords(input$title, input$description, cats[i])
        incProgress(0.7 / length(cats))
      }
    })
  })

  observeEvent(input$add_button, {
  cat <- input$add_category
  new_kws <- trimws(query_keywords(input$title, input$description, cat))

  existing_cats <- categories()
  existing_kws <- keywords[[cat]]
  
  norm_existing <- normalize_keywords(existing_kws)
  norm_new <- normalize_keywords(new_kws)
  to_add <- new_kws[!(norm_new %in% norm_existing)]

  if (!(cat %in% existing_cats)) {
    categories(c(existing_cats, cat))
  }

  keywords[[cat]] <- unique(c(existing_kws, format_keywords(to_add)))
})

observeEvent(input$add_keyword, {
  req(input$manual_keyword)
  cat <- input$selected_category
  if (!is.null(cat) && cat %in% categories()) {
    new_keywords <- unique(trimws(unlist(strsplit(input$manual_keyword, "\\s*[,;]\\s*"))))
    existing <- keywords[[cat]]
    norm_existing <- normalize_keywords(existing)
    norm_new <- normalize_keywords(new_keywords)
    to_add <- new_keywords[!(norm_new %in% norm_existing)]
    if (length(to_add) > 0) {
      keywords[[cat]] <- c(existing, format_keywords(to_add))
    }
  }
})

  observeEvent(input$grab_doi, {
  req(input$doi_input)
  withProgress(message = "Fetching metadata...", value = 0, {
    md <- get_dataset_metadata(input$doi_input)
    
    # Update text inputs
    updateTextInput(session, "title", value = md$title)
    updateTextAreaInput(session, "description", value = md$description)

    # Match and set categories
    matched_cats <- match_to_categories(md$subjects)
    categories(matched_cats)

    # Update keywords by category
    for (cat in matched_cats) {
      # Add all keywords under each category (could be improved with smarter mapping)
      keywords[[cat]] <- unique(format_keywords(md$keywords))
    }
  })
})

observeEvent(input$regen_llm, {
  req(input$title, input$description)
  withProgress(message = "Generating suggestions...", value = 0, {
    new_cats <- match_to_categories(query_categories(input$title, input$description))
    incProgress(0.3)

    current_cats <- categories()
    updated_cats <- unique(c(current_cats, new_cats))
    categories(updated_cats)

    for (cat in new_cats) {
      new_kws <- trimws(query_keywords(input$title, input$description, cat))
      existing_kws <- keywords[[cat]]
      
      norm_existing <- normalize_keywords(existing_kws)
      norm_new <- normalize_keywords(new_kws)
      to_add <- new_kws[!(norm_new %in% norm_existing)]

      keywords[[cat]] <- unique(c(existing_kws, format_keywords(to_add)))
    }
  })
})




observeEvent(input$reset_all, {
  updateTextInput(session, "title", value = "")
  updateTextAreaInput(session, "description", value = "")
  updateTextInput(session, "manual_keyword", value = "")
  categories(NULL)
  for (nm in names(keywords)) {
    keywords[[nm]] <- NULL
  }
})

  output$category_tags <- renderUI({
    req(categories())
    tagList(
      lapply(categories(), function(cat) {
        remove_btn_id <- paste0("remove_category_", gsub("\\W", "_", cat))
        observeEvent(input[[remove_btn_id]], {
          categories(setdiff(categories(), cat))
          keywords[[cat]] <- NULL
        }, ignoreInit = TRUE)
        div(
          tags$span(cat, class = "subject-badge"),
          actionButton(remove_btn_id, "x", class = "btn btn-danger btn-sm")
        )
      })
    )
  })

  output$keyword_lists <- renderUI({
    req(categories())
    tagList(
      lapply(categories(), function(cat) {
        tagList(
          tags$h5(cat),
          div(
            lapply(seq_along(keywords[[cat]]), function(i) {
              keyword <- keywords[[cat]][i]
              remove_id <- paste0("remove_kw_", digest::digest(list(cat, keyword, i)))
              observeEvent(input[[remove_id]], {
                isolate({
                  current <- keywords[[cat]]
                  keywords[[cat]] <- current[current != keyword]
                })
              }, ignoreInit = TRUE)
              span(
                class = "keyword-badge",
                keyword,
                actionButton(remove_id, "x", class = "btn btn-sm btn-outline-danger keyword-remove-btn")
              )
            })
          )
        )
      })
    )
  })
}

shinyApp(ui, server)

