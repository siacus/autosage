library(shiny)
library(shinydashboard)
library(httr)
library(jsonlite)
library(stringr)
library(stringdist)
library(shinyWidgets)

subjects <- fromJSON("categories.json")

create_prompt <- function(title, description) {
  formatted_subjects <- paste0("['", paste(subjects, collapse = "', '"), "]")
  sprintf(
    "<s>[INST] Here are Title and Description of a dataset. Title :' %s ' Description:' %s '. And this are subject categories: %s. Please return only a json list of at most 3 elements corresponding to the text labels:",
    title, description, formatted_subjects
  )
}

fos_to_app_subject <- list(
  "Biological sciences" = "Medicine, Health and Life Sciences",
  "Mathematics" = "Mathematical Sciences",
  "Computer and information sciences" = "Computer and Information Science",
  "Physical sciences" = "Physics",
  "Chemical sciences" = "Chemistry",
  "Earth and related environmental sciences" = "Earth and Environmental Sciences",
  "Agricultural sciences" = "Agricultural Sciences",
  "Medical and Health sciences" = "Medicine, Health and Life Sciences",
  "Engineering and technology" = "Engineering",
  "Psychology" = "Social Sciences",
  "Social sciences" = "Social Sciences",
  "Economics and business" = "Business and Management",
  "Law" = "Law",
  "Arts" = "Arts and Humanities",
  "History and archaeology" = "Arts and Humanities",
  "Languages and literature" = "Arts and Humanities",
  "Philosophy, ethics and religion" = "Arts and Humanities",
  "Astronomy" = "Astronomy and Astrophysics"
)

map_fos_to_app_subject <- function(fos_labels) {
  vapply(fos_labels, function(fos) {
    clean_fos <- trimws(sub("^FOS:\\s*", "", fos))
    # Try direct mapping
    mapped <- fos_to_app_subject[[clean_fos]]
    if (!is.null(mapped)) return(mapped)
    # Fallback fuzzy match
    dists <- stringdist::stringdist(tolower(clean_fos), tolower(categories), method = "jw")
    best <- which.min(dists)
    if (dists[best] < 0.2) categories[best] else NA
  }, character(1))
}

append_keywords <- function(existing, new) {
  norm_existing <- normalize_keywords(existing)
  norm_new <- normalize_keywords(new)
  to_add <- new[!(norm_new %in% norm_existing)]
  unique(c(existing, format_keywords(to_add)))
}

guess_repository_from_doi <- function(doi) {
  doi <- sub(".*(10\\.[0-9]+/[^\\s]+)", "\\1", doi)

  # Known patterns (fast)
  if (grepl("^10\\.7910/DVN", doi, ignore.case = TRUE)) return("dataverse")
  if (grepl("^10\\.5281/zenodo", doi, ignore.case = TRUE)) return("zenodo")
  if (grepl("^10\\.6084/m9.figshare", doi, ignore.case = TRUE)) return("figshare")
  if (grepl("^10\\.5061/dryad", doi, ignore.case = TRUE)) return("dryad")
  if (grepl("^10\\.17632/", doi, ignore.case = TRUE)) return("mendeley")
  if (grepl("^10\\.25934/", doi, ignore.case = TRUE)) return("vivli")
  if (grepl("osf.io", doi, ignore.case = TRUE)) return("osf")

  # Fallback: resolve via DataCite
  tryCatch({
    res <- httr::GET(paste0("https://api.datacite.org/dois/", URLencode(doi, reserved = TRUE)))
    if (res$status_code != 200) return("unknown")

    data <- jsonlite::fromJSON(httr::content(res, as = "text", encoding = "UTF-8"))
    landing_url <- data$data$attributes$url

    # Heuristic: Dataverse landing pages often have /citation?persistentId=doi:
    if (grepl("/citation\\?persistentId=doi:", landing_url, fixed = FALSE)) {
      return("dataverse")
    }

    return("unknown")
  }, error = function(e) {
    return("unknown")
  })
}


get_metadata_from_dataverse <- function(doi) {
  doi <- sub(".*(10\\.[0-9]+/[^\\s]+)", "\\1", doi)

  base_url <- tryCatch({
    res <- httr::GET(paste0("https://api.datacite.org/dois/", URLencode(doi, reserved = TRUE)))
    if (res$status_code != 200) stop("Failed to resolve DOI")
    data <- jsonlite::fromJSON(httr::content(res, as = "text", encoding = "UTF-8"))
    landing_url <- data$data$attributes$url
    sub("/citation\\?.*", "", landing_url)
  }, error = function(e) {
    warning("Could not resolve Dataverse base URL, falling back to Harvard")
    "https://dataverse.harvard.edu"
  })

  # Extract installation name
  install_name <- tools::toTitleCase(sub("https?://(dataverse\\.)?|\\..*", "", basename(base_url)))
  publisher <- tolower(data$data$attributes$publisher)
  

  # Query Dataverse API
  api_url <- paste0(base_url, "/api/datasets/:persistentId")
  res <- httr::GET(api_url, query = list(persistentId = paste0("doi:", doi)))
  if (res$status_code != 200) stop("Failed to fetch dataset info from Dataverse.")

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
    raw_keywords <- kw_block$keywordValue$value
    split_keywords(raw_keywords)
  }, error = function(e) character(0))

  list(
    title = title,
    description = description,
    subjects = subjects,
    keywords = keywords,
    repo_label = paste("Dataverse (", publisher, ")", sep = "")
  )
}




get_metadata_from_dryad <- function(doi) {
  doi <- sub(".*(10\\.[0-9]+/[^\\s]+)", "\\1", doi)
  url <- paste0("https://api.datacite.org/dois/", URLencode(doi, reserved = TRUE))

  res <- httr::GET(url)
  if (res$status_code != 200) stop("Failed to fetch metadata from DataCite for Dryad.")

  full_data <- jsonlite::fromJSON(content(res, as = "text", encoding = "UTF-8"))

  if (!"data" %in% names(full_data) || !"attributes" %in% names(full_data$data)) {
    stop("Unexpected metadata format from DataCite.")
  }

  data <- full_data$data$attributes
  title <- tryCatch({
    if (is.data.frame(data$titles) && "title" %in% names(data$titles)) {
      data$titles$title[1]
    } else NA
  }, error = function(e) NA)

  description <- tryCatch({
    if (!is.null(data$descriptions) && is.data.frame(data$descriptions) && nrow(data$descriptions) > 0) {
      abstract_row <- data$descriptions[data$descriptions$descriptionType == "Abstract", ]
      if (nrow(abstract_row) > 0) {
        abstract_row$description[1]
      } else {
        data$descriptions$description[1]
      }
    } else NA
  }, error = function(e) NA)

  subjects <- tryCatch({
    if(is.null(data$subjects)) character(0)
    idx <- grep("FOS:", data$subjects$subject)
    if(length(idx)==0) character(0)
    cleaned <- substring(data$subjects$subject[idx], 5)
    cleaned <- map_fos_to_app_subject(cleaned)
    unique(na.omit(trimws(cleaned)))
  }, error = function(e) character(0))

  keywords <- tryCatch({
    if(is.null(data$subjects)) character(0)
    idx <- which(is.na(data$subjects$subjectScheme) | data$subjects$subjectScheme == "")
    if(length(idx)==0) character(0)
    unique(na.omit(trimws(data$subjects$subject[idx])))
  }, error = function(e) character(0))

  list(
    title = title,
    description = description,
    subjects = subjects,
    keywords = keywords
  )
}

split_keywords <- function(raw_keywords){
    # Handle multiple separators: , ; | newline or tab
    if(length(raw_keywords)== 0) return(character(0))
    parts <- unlist(strsplit(raw_keywords, "\\s*(,|;|\\||\\n|\\t)\\s*"))
    parts <- trimws(parts)
    parts <- parts[nzchar(parts)]
    tools::toTitleCase(unique(parts)) 
}

get_metadata_from_mendeley <- function(doi) {
  doi <- sub(".*(10\\.\\d{4,9}/[^\\s]+)", "\\1", doi)
  record_id <- sub(".*/", "", doi)  # Extract dataset ID
  record_id <- sub("\\.\\d+$", "", record_id)  # Remove version suffix (e.g., .2)

  url <- paste0("https://data.mendeley.com/public-api/datasets/", record_id)
  res <- httr::GET(url)

  if (res$status_code != 200) stop("Failed to fetch metadata from Mendeley Data.")

  data <- jsonlite::fromJSON(httr::content(res, as = "text", encoding = "UTF-8"))
  title <- data$name
  description <- data$description
  raw_keywords <- tryCatch(data$categories$label, error = function(e) character(0))
  keywords <- split_keywords(raw_keywords)

  subjects <- if (!is.null(data$discipline)) data$discipline else "Other"

  list(
    title = title,
    description = description,
    subjects = match_to_categories(keywords),
    keywords = split_keywords(keywords)
  )
}

get_metadata_from_osf <- function(doi) {
  # Normalize the DOI to extract only the OSF ID (e.g., "y2nrb")
  osf_id <- toupper(sub(".*osf\\.io/([a-z0-9]+)", "\\1", tolower(doi)))
  url <- paste0("https://api.osf.io/v2/guids/", osf_id, "/")

  res <- httr::GET(url)
  if (res$status_code != 200) stop("Failed to fetch metadata from OSF.")

  data <- jsonlite::fromJSON(httr::content(res, as = "text", encoding = "UTF-8"))
  title <- tryCatch(data$data$attributes$title, error = function(e) NA)
  description <- tryCatch(data$data$attributes$description, error = function(e) NA)
  raw_keywords <- tryCatch(data$data$attributes$tags, error = function(e) character(0))
  keywords <- split_keywords(raw_keywords)
  # Subjects come from nested list of data frames
  raw_subjects <- tryCatch({
    subject_blocks <- data$data$attributes$subjects
    if (length(subject_blocks) == 0) character(0)
    match_to_categories( unlist(lapply(subject_blocks, function(s) s$text)) )
  }, error = function(e) character(0))
  # Refine: try to match keywords to additional subject categories
  all_subjects <- unique(c(raw_subjects, match_to_categories(keywords, max_dist = 0.1)))


  list(
    title = title,
    description = description,
    subjects = all_subjects,
    keywords = keywords
  )
}


get_metadata_from_vivli <- function(doi) {
  doi <- sub(".*(10\\.25934/[^\\s]+)", "\\1", doi)
  url <- paste0("https://api.datacite.org/dois/", URLencode(doi, reserved = TRUE))
  res <- httr::GET(url)
  if (res$status_code != 200) stop("Failed to fetch metadata from DataCite for Vivli.")

  data <- jsonlite::fromJSON(httr::content(res, as = "text", encoding = "UTF-8"))
  attr <- data$data$attributes

  # Extract title
  title <- tryCatch({
    titles <- attr$titles
    if (is.data.frame(titles) && "title" %in% names(titles)) {
      titles$title[which(nzchar(titles$title))[1]]
    } else NA
  }, error = function(e) NA)

  # Extract description
  description <- tryCatch({
    desc <- attr$descriptions
    if (is.data.frame(desc) && "description" %in% names(desc)) {
      desc$description[which(nzchar(desc$description))[1]]
    } else NA
  }, error = function(e) NA)

  # Extract and process keywords
  raw_keywords <- tryCatch(attr$subjects$subject, error = function(e) character(0))
  keywords <- split_keywords(raw_keywords)

  # Refined category match from keywords
  subjects <- match_to_categories(keywords, 0.1) 

  list(
    title = title,
    description = description,
    subjects = subjects,
    keywords = keywords
  )
}




get_metadata_from_zenodo <- function(doi) {
  record_id <- sub(".*zenodo\\.(\\d+)", "\\1", doi)
  url <- paste0("https://zenodo.org/api/records/", record_id)

  res <- httr::GET(url)
  if (res$status_code != 200) stop("Failed to fetch metadata from Zenodo.")

  data <- jsonlite::fromJSON(content(res, as = "text", encoding = "UTF-8"))

  title <- data$metadata$title
  description <- data$metadata$description

  raw_keywords <- data$metadata$keywords
  keywords <- character(0)
  
  keywords <- split_keywords(raw_keywords)
 
  list(
    title = title,
    description = description,
    subjects = "Other",
    keywords = keywords
  )
}


get_metadata_from_figshare <- function(doi) {
  # Extract numeric article ID (ignore version suffix)
  article_id <- sub(".*figshare\\.(\\d+)(\\.v\\d+)?", "\\1", doi)
  url <- paste0("https://api.figshare.com/v2/articles/", article_id)

  res <- httr::GET(url)
  if (res$status_code != 200) stop("Failed to fetch metadata from Figshare.")

  data <- jsonlite::fromJSON(content(res, as = "text", encoding = "UTF-8"))

  title <- data$title
  description <- data$description

  # Extract subject categories if present
  subjects <- character(0)
  if (!is.null(data$categories) && is.data.frame(data$categories)) {
    if ("title" %in% names(data$categories)) {
      subjects <- unique(trimws(data$categories$title))
    }
  }

  # Tags are used as keywords
  keywords <- data$tags
  if (is.null(keywords)) keywords <- character(0)

  list(title = title, description = description, subjects = subjects, keywords = keywords)
}



get_dataset_metadata <- function(doi) {
  repo <- guess_repository_from_doi(doi)
  fallback_if_null <- function(primary, fallback) {
    if (!is.null(primary)) primary else fallback
  }

  metadata <- switch(repo,
    "dataverse" = get_metadata_from_dataverse(doi),
    "zenodo"    = get_metadata_from_zenodo(doi),
    "figshare"  = get_metadata_from_figshare(doi),
    "dryad"     = get_metadata_from_dryad(doi),
    "mendeley"  = get_metadata_from_mendeley(doi),
    "vivli"     = get_metadata_from_vivli(doi),
    "osf"       = get_metadata_from_osf(doi),
    stop(paste("Unknown or unsupported repository for DOI:", doi))
  )

  metadata$repo_label <- fallback_if_null(metadata$repo_label, tools::toTitleCase(repo))

  return(metadata)
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
    if (best_distance <= max_dist) return(best_subject) else return("Other")
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




ui <- dashboardPage(
   dashboardHeader(
    # You can leave the default title empty or use it for the collapsed sidebar
    title = "AutoSage - AI Helper",
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
      actionButton("grab_doi", "Get Metadata From Repository"),
      tags$hr(),
      actionButton("regen_llm", "Suggest More Metadata"),
      actionButton("reset_all", "Reset Data"),
      tags$hr(),
      tags$p(
        HTML('Bugs or suggestions? <a href="https://github.com/siacus/autosage" target="_blank">Visit the GitHub repo</a>.'),
        style = "text-align: center; font-size: 12px; color: #aaa; margin: 10px auto; padding: 0 10px;"
      ),
     tags$hr(),
      tags$p("© 2025 S.M. Iacus (Shiny App, AI Model), B. Treacy (AI Model)",
        style = "text-align: center; font-size: 12px; color: #aaa; margin: 10px auto; padding: 0 10px; word-wrap: break-word; white-space: normal;")
    )
  ),
  dashboardBody(
    tags$head(tags$style(HTML(".subject-badge {background-color: #6c757d; color: white; font-size: 1.1em; padding: 7px 12px; border-radius: 20px; margin: 4px; display: inline-block;} .keyword-badge {background-color: #e9ecef; border: 1px solid #6c757d; font-size: 0.85em; padding: 4px 8px; border-radius: 12px; margin: 3px; display: inline-block;} .keyword-remove-btn {margin-left: 6px; font-size: 0.75em; vertical-align: middle;}"))),
    fluidRow(
      box(width = 12, title = uiOutput("input_box_title"), status = "primary", solidHeader = TRUE,
          textInput("title", "Dataset Title", width = "100%"),
          textAreaInput("description", "Dataset Description", height = "200px", width = "100%"),
          fluidRow( column(width = 6, 
                            actionButton("generate", "Suggest Subject Categories") ),
                    column(width = 6, 
                            materialSwitch(inputId = "overwrite_keywords", label = "Overwrite Existing Keywords?",
                                            value = FALSE, status = "primary", right = TRUE ))
      )
    ),
    fluidRow(
      box(width = 12, title = "Suggested Subject Categories", status = "primary", solidHeader = TRUE, uiOutput("category_tags"))
    ),
    fluidRow(
      box(width = 12, title = "Keywords by Category", status = "info", solidHeader = TRUE, uiOutput("keyword_lists"))
    )
    )
))

normalize_keywords <- function(x) {
    tolower(trimws(x))
  }
  format_keywords <- function(x) {
    tools::toTitleCase(trimws(x))
  }

server <- function(input, output, session) {
  categories <- reactiveVal()
  keywords <- reactiveValues()
  repo_name <- reactiveVal(NULL)

  observeEvent(input$generate, {
  req(input$title, input$description)

  withProgress(message = "Generating suggestions...", value = 0, {
    # LLM category suggestions
    new_cats <- match_to_categories(query_categories(input$title, input$description))
    incProgress(0.3)

    # Merge with existing
    current_cats <- categories()
    updated_cats <- unique(c(current_cats, new_cats))
    categories(updated_cats)

    # Determine which categories to update
    target_cats <- if (isTRUE(input$overwrite_keywords)) updated_cats else new_cats

    for (cat in target_cats) {
      new_kws <- trimws(query_keywords(input$title, input$description, cat))

      if (isTRUE(input$overwrite_keywords)) {
        keywords[[cat]] <- unique(format_keywords(new_kws))
      } else {
        existing_kws <- keywords[[cat]]
        norm_existing <- normalize_keywords(existing_kws)
        norm_new <- normalize_keywords(new_kws)
        to_add <- new_kws[!(norm_new %in% norm_existing)]
        keywords[[cat]] <- unique(c(existing_kws, format_keywords(to_add)))
      }

      incProgress(0.7 / length(target_cats))
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

    md <- tryCatch({
      get_dataset_metadata(input$doi_input)
    }, error = function(e) {
      showNotification("This DOI is not supported or is invalid.", type = "error", duration = 6)
    return(NULL)
    })

    if (is.null(md)) return()  # Don't proceed if metadata retrieval failed

    repo_name(tools::toTitleCase(md$repo_label))  # Capitalize for display

    updateTextInput(session, "title", value = md$title)
    updateTextAreaInput(session, "description", value = md$description)

    matched_cats <- match_to_categories(md$subjects)
    categories(matched_cats)

    for (cat in matched_cats) {
      keywords[[cat]] <- unique(format_keywords(md$keywords))
    }
  })
})

output$input_box_title <- renderUI({
  if (!is.null(repo_name())) {
    paste0("Input Data: ", tools::toTitleCase(repo_name()))
  } else {
    "Input Data"
  }
})

#   observeEvent(input$grab_doi, {
#   req(input$doi_input)
#   withProgress(message = "Fetching metadata...", value = 0, {
#     md <- get_dataset_metadata(input$doi_input)
    
#     # Update text inputs
#     updateTextInput(session, "title", value = md$title)
#     updateTextAreaInput(session, "description", value = md$description)

#     # Match and set categories
#     matched_cats <- match_to_categories(md$subjects)
#     categories(matched_cats)

#     # Update keywords by category
#     for (cat in matched_cats) {
#       # Add all keywords under each category (could be improved with smarter mapping)
#       keywords[[cat]] <- unique(format_keywords(md$keywords))
#     }
#   })
# })

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
      
      if (isTRUE(input$overwrite_keywords)) {
        keywords[[cat]] <- unique(format_keywords(new_kws))
      } else {
        existing_kws <- keywords[[cat]]
        norm_existing <- normalize_keywords(existing_kws)
        norm_new <- normalize_keywords(new_kws)
        to_add <- new_kws[!(norm_new %in% norm_existing)]
        keywords[[cat]] <- unique(c(existing_kws, format_keywords(to_add)))
      }
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

