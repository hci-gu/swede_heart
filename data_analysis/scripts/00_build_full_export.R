#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  if (!requireNamespace("data.table", quietly = TRUE)) {
    stop("Package 'data.table' is required.", call. = FALSE)
  }
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("Package 'jsonlite' is required to read raw user JSON files.", call. = FALSE)
  }
})

library(data.table)

usage <- function() {
  cat("
Build a full Swedeheart export using R only.

This is intended for the secure analysis server: upload/sync the raw download
directory, then run this script there. It creates the tidy raw health export,
daily health records, metadata, checksums, and optional clinical alignment.

Required:
  --raw-data-dir PATH                  Raw download root containing users/, or users/ itself.
  --output-dir PATH                    Export directory to create.

Optional:
  --keys PATH                          Key file for clinical alignment.
  --clinical PATH                      Clinical file for clinical alignment.
  --skip-alignment true|false          Default: false when keys+clinical are set, otherwise true.
  --include-personal-id-in-main true|false
                                       Default: false. Keep direct identifiers only in keys_sensitive_separate/.
  --skip-raw-health-records true|false Default: false. Omit raw/health_records.csv.gz and skip raw-only serialization.
  --skip-daily-health-records-gz true|false
                                       Default: false. Omit derived/daily_health_records.csv.gz.
  --workers N                          Default: 1. Parallel user transforms for aligned-only exports.
  --test-run true|false                Default: false. Process only one worker batch end-to-end.
  --bucket-minutes N                   Default: 10.
  --exact-interval true|false          Default: false.
  --gzip-level N                       Default: 1. Use 6 for smaller files, slower writes.
  --clinical-sheet NAME                Default: RiksHia.
  --clinical-key-col NAME              Default: pseudo_PNR.
  --clinical-heartattack-date-col NAME Default: P.
  --clinical-heartattack-type-col NAME Default: GJ.
  --clinical-physio-sheet NAME         Default: Physio.
  --clinical-physio-key-col NAME       Default: --clinical-key-col.
  --clinical-physio-value-cols COLS    Default: E,F,G.
  --window-before DAYS
  --window-after DAYS
  --alignment-script PATH              Default: 01_build_aligned_dataset.R next to this script.
  --help

Main outputs:
  raw/health_records.csv.gz, unless --skip-raw-health-records true
  derived/daily_health_records.csv.gz, unless --skip-daily-health-records-gz true
  export_logs/daily_health_records_transform/daily_health_records.csv
  keys_sensitive_separate/personal_id_map.csv
  manifest.json
  checksums.md5

Clinical outputs, when keys and clinical are provided:
  derived/clinical_alignment/subject_index.csv
  derived/clinical_alignment/health_records_aligned.csv
  derived/clinical_alignment/daily_features_aligned.csv
")
}

parse_args <- function(args) {
  result <- list(
    raw_data_dir = NULL,
    output_dir = NULL,
    keys = NULL,
    clinical = NULL,
    skip_alignment = NULL,
    include_personal_id_in_main = "false",
    skip_raw_health_records = "false",
    skip_daily_health_records_gz = "false",
    workers = "1",
    test_run = "false",
    bucket_minutes = "10",
    exact_interval = "false",
    gzip_level = "1",
    clinical_sheet = "RiksHia",
    clinical_key_col = "pseudo_PNR",
    clinical_heartattack_date_col = "P",
    clinical_heartattack_type_col = "GJ",
    clinical_physio_sheet = "Physio",
    clinical_physio_key_col = "",
    clinical_physio_value_cols = "E,F,G",
    window_before = NULL,
    window_after = NULL,
    alignment_script = NULL
  )

  i <- 1
  while (i <= length(args)) {
    key <- args[[i]]
    if (key == "--help" || key == "-h") {
      usage()
      quit(status = 0)
    }
    if (!startsWith(key, "--")) {
      stop(sprintf("Unexpected argument: %s", key), call. = FALSE)
    }
    if (i == length(args)) {
      stop(sprintf("Missing value for %s", key), call. = FALSE)
    }

    value <- args[[i + 1]]
    name <- gsub("-", "_", substring(key, 3), fixed = TRUE)
    if (!name %in% names(result)) {
      stop(sprintf("Unknown argument: %s", key), call. = FALSE)
    }
    result[[name]] <- value
    i <- i + 2
  }

  result
}

as_flag <- function(value, default = FALSE) {
  if (is.null(value) || is.na(value) || value == "") {
    return(default)
  }
  normalized <- tolower(trimws(as.character(value)))
  if (normalized %in% c("true", "t", "yes", "y", "1")) {
    return(TRUE)
  }
  if (normalized %in% c("false", "f", "no", "n", "0")) {
    return(FALSE)
  }
  stop(sprintf("Expected true/false value, got: %s", value), call. = FALSE)
}

require_arg <- function(args, name) {
  if (is.null(args[[name]]) || is.na(args[[name]]) || args[[name]] == "") {
    stop(sprintf("Missing required argument --%s", gsub("_", "-", name)), call. = FALSE)
  }
}

script_dir <- function() {
  command_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- "--file="
  matches <- grep(paste0("^", file_arg), command_args, value = TRUE)
  if (length(matches)) {
    return(dirname(normalizePath(sub(file_arg, "", matches[[1]]), mustWork = TRUE)))
  }
  getwd()
}

resolve_users_dir <- function(raw_data_dir) {
  raw_data_dir <- normalizePath(raw_data_dir, mustWork = TRUE)
  if (basename(raw_data_dir) == "users") {
    users_dir <- raw_data_dir
  } else {
    users_dir <- file.path(raw_data_dir, "users")
  }
  if (!dir.exists(users_dir)) {
    stop(sprintf("Could not find users/ under %s", raw_data_dir), call. = FALSE)
  }
  users_dir
}

normalize_personal_id <- function(value) {
  normalized <- trimws(as.character(value))
  digits <- gsub("[^0-9]", "", normalized)
  has_full_pnr <- !is.na(digits) & nchar(digits) == 12
  normalized[has_full_pnr] <- paste0(
    substr(digits[has_full_pnr], 1, 8),
    "-",
    substr(digits[has_full_pnr], 9, 12)
  )
  normalized[normalized == ""] <- NA_character_
  normalized
}

normalize_key <- function(value) {
  normalized <- trimws(as.character(value))
  normalized[normalized == ""] <- NA_character_
  normalized
}

is_excel_column_ref <- function(value) {
  is.character(value) &&
    length(value) == 1 &&
    nchar(value) <= 3 &&
    grepl("^[A-Za-z]+$", value)
}

excel_column_index <- function(value) {
  letters <- strsplit(toupper(value), "", fixed = TRUE)[[1]]
  result <- 0L
  for (letter in letters) {
    result <- result * 26L + match(letter, LETTERS)
  }
  result
}

resolve_named_col <- function(data, col) {
  if (col %in% names(data)) {
    return(col)
  }
  prefixed <- names(data)[startsWith(names(data), paste0(col, " "))]
  if (length(prefixed) == 1L) {
    return(prefixed[[1]])
  }
  NULL
}

select_test_col <- function(data, selector) {
  resolved <- resolve_named_col(data, selector)
  if (!is.null(resolved)) {
    return(data[[resolved]])
  }
  if (is_excel_column_ref(selector)) {
    index <- excel_column_index(selector)
    if (index <= ncol(data)) {
      return(data[[index]])
    }
  }
  NULL
}

read_test_key_table <- function(path) {
  extension <- tolower(tools::file_ext(path))
  if (extension %in% c("xlsx", "xls")) {
    if (!requireNamespace("readxl", quietly = TRUE)) {
      return(data.table())
    }
    keys <- as.data.table(suppressMessages(readxl::read_excel(path, col_names = FALSE)))
    if (ncol(keys) < 2L) {
      return(data.table())
    }
    setnames(keys, paste0("col", seq_len(ncol(keys))))
    return(keys[, .(pseudo_PNR = normalize_key(col1), personalId = normalize_personal_id(col2))])
  }

  keys <- fread(path)
  pseudo_col <- resolve_named_col(keys, "pseudo_PNR")
  if (is.null(pseudo_col)) {
    pseudo_col <- names(keys)[[1]]
  }
  personal_col <- resolve_named_col(keys, "personalId")
  if (is.null(personal_col)) {
    if (ncol(keys) < 2L) {
      return(data.table())
    }
    personal_col <- names(keys)[[2]]
  }
  keys[, .(pseudo_PNR = normalize_key(get(pseudo_col)), personalId = normalize_personal_id(get(personal_col)))]
}

read_test_clinical_keys <- function(path, clinical_sheet, clinical_key_col, heartattack_date_col) {
  extension <- tolower(tools::file_ext(path))
  if (extension %in% c("xlsx", "xls")) {
    if (!requireNamespace("readxl", quietly = TRUE)) {
      return(character())
    }
    clinical <- as.data.table(suppressMessages(
      readxl::read_excel(path, sheet = clinical_sheet, col_names = TRUE)
    ))
  } else {
    clinical <- fread(path)
  }

  key_values <- select_test_col(clinical, clinical_key_col)
  date_values <- select_test_col(clinical, heartattack_date_col)
  if (is.null(key_values) || is.null(date_values)) {
    return(character())
  }
  key_values <- normalize_key(key_values)
  date_values <- trimws(as.character(date_values))
  unique(key_values[!is.na(key_values) & !is.na(date_values) & date_values != ""])
}

eligible_test_personal_ids <- function(args) {
  if (is.null(args$keys) || is.null(args$clinical) || args$keys == "" || args$clinical == "") {
    return(character())
  }
  keys <- read_test_key_table(args$keys)
  if (!nrow(keys)) {
    return(character())
  }
  clinical_keys <- read_test_clinical_keys(
    args$clinical,
    args$clinical_sheet,
    args$clinical_key_col,
    args$clinical_heartattack_date_col
  )
  if (!length(clinical_keys)) {
    return(character())
  }
  unique(keys[pseudo_PNR %in% clinical_keys & !is.na(personalId), personalId])
}

csv_escape <- function(value) {
  text <- as.character(value)
  text[is.na(text)] <- ""
  needs_quote <- grepl("[\",\n\r]", text)
  text <- gsub("\"", "\"\"", text, fixed = TRUE)
  text[needs_quote] <- paste0("\"", text[needs_quote], "\"")
  text
}

write_csv_lines <- function(con, rows, fields) {
  if (!nrow(rows)) {
    return(invisible(NULL))
  }
  missing_fields <- setdiff(fields, names(rows))
  for (field in missing_fields) {
    rows[, (field) := ""]
  }
  setcolorder(rows, fields)
  lines <- do.call(
    paste,
    c(lapply(fields, function(field) csv_escape(rows[[field]])), sep = ",")
  )
  writeLines(lines, con = con, sep = "\n", useBytes = TRUE)
}

parse_timestamp <- function(value) {
  parsed <- parse_timestamps(value)
  if (!length(parsed)) {
    return(as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"))
  }
  parsed[[1]]
}

parse_timestamps <- function(value) {
  if (is.null(value)) {
    return(as.POSIXct(character(), tz = "UTC"))
  }
  text <- as.character(value)
  missing <- is.na(value) | text == ""
  text[missing] <- NA_character_
  text <- sub("Z$", "", text)
  text <- sub("([+-][0-9]{2}):([0-9]{2})$", "\\1\\2", text)
  suppressWarnings(
    as.POSIXct(
      text,
      tz = "UTC",
      tryFormats = c(
        "%Y-%m-%dT%H:%M:%OS%z",
        "%Y-%m-%dT%H:%M:%OS",
        "%Y-%m-%d %H:%M:%OS"
      )
    )
  )
}

timestamp_text <- function(value) {
  formatted <- format(value, "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  formatted[is.na(value)] <- ""
  unname(formatted)
}

floor_to_bucket <- function(timestamp, bucket_minutes) {
  seconds <- as.numeric(timestamp)
  bucket_seconds <- bucket_minutes * 60
  bucketed <- as.POSIXct(
    floor(seconds / bucket_seconds) * bucket_seconds,
    origin = "1970-01-01",
    tz = "UTC"
  )
  bucketed[is.na(timestamp)] <- as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC")
  bucketed
}

json_scalar <- function(record, name) {
  value <- record[[name]]
  if (is.null(value) || length(value) == 0) "" else as.character(value[[1]])
}

numeric_value_from_record <- function(record) {
  value <- record[["value"]]
  if (!is.list(value) || is.null(value[["numericValue"]]) || is.logical(value[["numericValue"]])) {
    return(NA_real_)
  }
  suppressWarnings(as.numeric(value[["numericValue"]]))
}

value_json_from_record <- function(record) {
  value <- record[["value"]]
  if (is.null(value)) {
    return("")
  }
  jsonlite::toJSON(value, auto_unbox = TRUE, null = "null", digits = NA)
}

scalar_text <- function(value) {
  if (is.null(value) || length(value) == 0) {
    return("")
  }
  item <- value[[1]]
  if (is.null(item) || length(item) == 0) {
    return("")
  }
  if (length(item) > 1) {
    item <- item[[1]]
  }
  if (is.na(item)) {
    return("")
  }
  as.character(item)
}

table_character_column <- function(rows, name, default = "") {
  row_count <- nrow(rows)
  if (!name %in% names(rows)) {
    return(rep(default, row_count))
  }
  value <- rows[[name]]
  if (is.data.frame(value)) {
    return(rep(default, row_count))
  }
  if (is.list(value) && !is.atomic(value)) {
    return(vapply(value, scalar_text, character(1), USE.NAMES = FALSE))
  }
  text <- as.character(value)
  text[is.na(text)] <- default
  text
}

scalar_numeric <- function(value) {
  if (is.null(value) || length(value) == 0) {
    return(NA_real_)
  }
  item <- value[[1]]
  if (is.null(item) || length(item) == 0) {
    return(NA_real_)
  }
  if (length(item) > 1) {
    item <- item[[1]]
  }
  if (is.logical(item)) {
    return(NA_real_)
  }
  suppressWarnings(as.numeric(item))
}

table_numeric_column <- function(rows, candidates) {
  row_count <- nrow(rows)
  for (name in candidates) {
    if (!name %in% names(rows)) {
      next
    }
    value <- rows[[name]]
    if (is.data.frame(value)) {
      next
    }
    if (is.list(value) && !is.atomic(value)) {
      return(vapply(value, scalar_numeric, numeric(1), USE.NAMES = FALSE))
    }
    if (is.logical(value)) {
      return(rep(NA_real_, length(value)))
    }
    return(suppressWarnings(as.numeric(value)))
  }
  rep(NA_real_, row_count)
}

aggregation_for <- function(data_type) {
  fifelse(data_type == "STEPS", "sum", "mean")
}

daily_rows_for_user <- function(raw_rows, bucket_minutes, exact_interval) {
  numeric_rows <- raw_rows[!is.na(numeric_value) & !is.na(parsed_date_from)]
  if (!nrow(numeric_rows)) {
    return(data.table())
  }

  if (exact_interval) {
    numeric_rows[
      ,
      bucket_key := paste(
        data_type,
        unit,
        timestamp_text(parsed_date_from),
        timestamp_text(parsed_date_to),
        sep = "\r"
      )
    ]
  } else {
    numeric_rows[
      ,
      bucket_start := floor_to_bucket(parsed_date_from, bucket_minutes)
    ]
    numeric_rows[
      ,
      bucket_key := paste(
        data_type,
        unit,
        timestamp_text(bucket_start),
        "",
        sep = "\r"
      )
    ]
  }

  numeric_rows[, aggregation := aggregation_for(data_type)]

  step_buckets <- numeric_rows[
    aggregation == "sum",
    .(
      subject_id = subject_id[1],
      date = date[1],
      dataType = data_type[1],
      unit = unit[1],
      aggregation = aggregation[1],
      bucket_value = max(numeric_value, na.rm = TRUE),
      sourceRecords = .N,
      collapsedDuplicateRecords = .N - 1L
    ),
    by = bucket_key
  ]

  mean_buckets <- numeric_rows[
    aggregation == "mean",
    .(
      subject_id = subject_id[1],
      date = date[1],
      dataType = data_type[1],
      unit = unit[1],
      aggregation = aggregation[1],
      bucket_value = mean(numeric_value, na.rm = TRUE),
      sourceRecords = .N,
      collapsedDuplicateRecords = .N - 1L
    ),
    by = bucket_key
  ]

  buckets <- rbindlist(list(step_buckets, mean_buckets), use.names = TRUE, fill = TRUE)
  if (!nrow(buckets)) {
    return(data.table())
  }

  daily <- buckets[
    ,
    .(
      value = if (aggregation[1] == "sum") sum(bucket_value, na.rm = TRUE) else mean(bucket_value, na.rm = TRUE),
      buckets = .N,
      sourceRecords = sum(sourceRecords),
      collapsedDuplicateRecords = sum(collapsedDuplicateRecords)
    ),
    by = .(subject_id, date, dataType, unit, aggregation)
  ]
  setorder(daily, subject_id, date, dataType, unit)
  daily[
    ,
    value := fifelse(
      is.finite(value) & value == floor(value),
      as.character(as.integer(value)),
      sub("\\.?0+$", "", sprintf("%.6f", value))
    )
  ]
  daily
}

empty_records_table <- function(include_personal_id, include_raw_columns) {
  if (include_raw_columns) {
    fields <- c(
      "subject_id",
      "record_id",
      "record_index",
      "data_type",
      "unit",
      "numeric_value",
      "value_json",
      "date_from",
      "date_to",
      "date",
      "platform_type",
      "device_id",
      "source_id",
      "source_name",
      "source_file",
      "parsed_date_from",
      "parsed_date_to"
    )
  } else {
    fields <- c(
      "subject_id",
      "data_type",
      "unit",
      "numeric_value",
      "date",
      "parsed_date_from",
      "parsed_date_to"
    )
  }
  if (include_personal_id) {
    fields <- c(fields, "personalId")
  }
  empty <- data.table()
  for (field in fields) {
    empty[, (field) := character()]
  }
  empty[, numeric_value := numeric()]
  if (include_raw_columns) {
    empty[, record_index := integer()]
  }
  empty[, parsed_date_from := as.POSIXct(character(), tz = "UTC")]
  empty[, parsed_date_to := as.POSIXct(character(), tz = "UTC")]
  empty
}

records_for_user_fast_daily <- function(path, subject_id, personal_id, source_file, include_personal_id) {
  records <- tryCatch(
    jsonlite::fromJSON(path, simplifyVector = TRUE, simplifyDataFrame = TRUE, flatten = TRUE),
    error = function(error) NULL
  )
  if (!is.data.frame(records)) {
    return(NULL)
  }

  record_count <- nrow(records)
  if (!record_count) {
    return(empty_records_table(include_personal_id, include_raw_columns = FALSE))
  }

  date_from <- table_character_column(records, "date_from")
  date_to <- table_character_column(records, "date_to")
  date <- rep("", record_count)
  has_date <- nchar(date_from) >= 10L
  date[has_date] <- substr(date_from[has_date], 1L, 10L)

  rows <- data.table(
    subject_id = rep(subject_id, record_count),
    data_type = table_character_column(records, "data_type"),
    unit = table_character_column(records, "unit"),
    numeric_value = table_numeric_column(
      records,
      c("value.numericValue", "value_numericValue", "numericValue")
    ),
    date = date,
    parsed_date_from = parse_timestamps(date_from),
    parsed_date_to = parse_timestamps(date_to)
  )
  if (include_personal_id) {
    rows[, personalId := personal_id]
  }
  rows
}

records_for_user <- function(path, subject_id, personal_id, source_file, include_personal_id, include_raw_columns) {
  if (!include_raw_columns) {
    fast_rows <- records_for_user_fast_daily(path, subject_id, personal_id, source_file, include_personal_id)
    if (!is.null(fast_rows)) {
      return(fast_rows)
    }
  }

  records <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  if (!is.list(records)) {
    stop(sprintf("Expected %s to contain a JSON array.", path), call. = FALSE)
  }
  record_count <- length(records)
  if (!record_count) {
    return(empty_records_table(include_personal_id, include_raw_columns))
  }

  record_index <- seq_len(record_count)
  data_type <- rep("", record_count)
  unit <- rep("", record_count)
  numeric_value <- rep(NA_real_, record_count)
  date_from <- rep("", record_count)
  date_to <- rep("", record_count)
  date <- rep("", record_count)
  if (include_raw_columns) {
    value_json <- rep("", record_count)
    platform_type <- rep("", record_count)
    device_id <- rep("", record_count)
    source_id <- rep("", record_count)
    source_name <- rep("", record_count)
  }

  for (index in record_index) {
    record <- records[[index]]
    if (!is.list(record)) {
      if (include_raw_columns) {
        value_json[[index]] <- jsonlite::toJSON(record, auto_unbox = TRUE, null = "null", digits = NA)
      }
    } else {
      data_type[[index]] <- json_scalar(record, "data_type")
      unit[[index]] <- json_scalar(record, "unit")
      numeric_value[[index]] <- numeric_value_from_record(record)
      date_from[[index]] <- json_scalar(record, "date_from")
      date_to[[index]] <- json_scalar(record, "date_to")
      if (include_raw_columns) {
        value_json[[index]] <- value_json_from_record(record)
        platform_type[[index]] <- json_scalar(record, "platform_type")
        device_id[[index]] <- json_scalar(record, "device_id")
        source_id[[index]] <- json_scalar(record, "source_id")
        source_name[[index]] <- json_scalar(record, "source_name")
      }
    }
  }

  has_date <- nchar(date_from) >= 10L
  date[has_date] <- substr(date_from[has_date], 1L, 10L)

  rows <- data.table(
    subject_id = rep(subject_id, record_count),
    data_type = data_type,
    unit = unit,
    numeric_value = numeric_value,
    date = date,
    parsed_date_from = parse_timestamps(date_from),
    parsed_date_to = parse_timestamps(date_to)
  )
  if (include_raw_columns) {
    rows[
      ,
      `:=`(
        record_id = paste0(subject_id, ":", sprintf("%08d", record_index)),
        record_index = record_index,
        value_json = value_json,
        date_from = date_from,
        date_to = date_to,
        platform_type = platform_type,
        device_id = device_id,
        source_id = source_id,
        source_name = source_name,
        source_file = rep(source_file, record_count)
      )
    ]
    setcolorder(
      rows,
      c(
        "subject_id",
        "record_id",
        "record_index",
        "data_type",
        "unit",
        "numeric_value",
        "value_json",
        "date_from",
        "date_to",
        "date",
        "platform_type",
        "device_id",
        "source_id",
        "source_name",
        "source_file",
        "parsed_date_from",
        "parsed_date_to"
      )
    )
  }
  if (include_personal_id) {
    rows[, personalId := personal_id]
  }
  rows
}

write_daily_chunk <- function(path, daily, daily_fields) {
  if (nrow(daily)) {
    setcolorder(daily, daily_fields)
    fwrite(daily, path, col.names = FALSE, na = "")
  } else {
    file.create(path)
  }
  path
}

append_file_binary <- function(source_path, target_con, chunk_size = 1024L * 1024L) {
  if (!file.exists(source_path) || file.info(source_path)$size == 0) {
    return(invisible(NULL))
  }
  source_con <- file(source_path, open = "rb")
  on.exit(close(source_con), add = TRUE)
  repeat {
    bytes <- readBin(source_con, what = "raw", n = chunk_size)
    if (!length(bytes)) {
      break
    }
    writeBin(bytes, target_con, useBytes = TRUE)
  }
  invisible(NULL)
}

merge_named_counts <- function(target, counts) {
  if (!length(counts)) {
    return(target)
  }
  for (name in names(counts)) {
    current_count <- target[[name]]
    if (is.null(current_count)) {
      current_count <- 0L
    }
    target[[name]] <- current_count + counts[[name]]
  }
  target
}

format_duration <- function(seconds) {
  if (!is.finite(seconds) || is.na(seconds)) {
    return("unknown")
  }
  seconds <- max(0, as.integer(round(seconds)))
  hours <- seconds %/% 3600L
  minutes <- (seconds %% 3600L) %/% 60L
  secs <- seconds %% 60L
  if (hours > 0L) {
    return(sprintf("%dh %02dm %02ds", hours, minutes, secs))
  }
  if (minutes > 0L) {
    return(sprintf("%dm %02ds", minutes, secs))
  }
  sprintf("%ds", secs)
}

progress_line <- function(completed, total, started_at, raw_records, numeric_records, daily_rows) {
  elapsed <- as.numeric(difftime(Sys.time(), started_at, units = "secs"))
  rate <- completed / max(elapsed, 1e-9)
  remaining <- if (rate > 0) (total - completed) / rate else NA_real_
  sprintf(
    "[%d/%d] %.1f%% complete; elapsed %s; ETA %s; raw records: %d; numeric records: %d; daily rows: %d\n",
    completed,
    total,
    100 * completed / total,
    format_duration(elapsed),
    format_duration(remaining),
    raw_records,
    numeric_records,
    daily_rows
  )
}

transform_user_for_export <- function(i, chunk_dir = NULL) {
  path <- user_files[[i]]
  personal_id <- personal_ids[[i]]
  subject_id <- subject_map[[personal_id]]
  source_file <- file.path("users", basename(path))
  rows <- records_for_user(
    path,
    subject_id,
    personal_id,
    source_file,
    include_personal_id,
    include_raw_columns = !skip_raw_health_records
  )

  user_type_counts <- rows[data_type != "", .N, by = data_type]
  daily <- daily_rows_for_user(rows, bucket_minutes, exact_interval)
  if (include_personal_id && nrow(daily)) {
    daily[, personalId := personal_id]
  }

  chunk_path <- NULL
  if (!is.null(chunk_dir)) {
    chunk_path <- file.path(chunk_dir, sprintf("%06d_daily.csv", i))
    write_daily_chunk(chunk_path, daily, daily_fields)
  }

  list(
    index = i,
    subject_id = subject_id,
    source_file = source_file,
    rawRecords = nrow(rows),
    numericRecords = rows[!is.na(numeric_value), .N],
    dailyRows = nrow(daily),
    dataTypes = as.list(setNames(user_type_counts$N, user_type_counts$data_type)),
    daily = if (is.null(chunk_dir)) daily else NULL,
    dailyChunk = chunk_path
  )
}

write_manifest <- function(path, manifest) {
  jsonlite::write_json(
    manifest,
    path,
    pretty = TRUE,
    auto_unbox = TRUE,
    null = "null",
    digits = NA
  )
  cat("\n", file = path, append = TRUE)
}

write_readme <- function(path) {
  lines <- c(
    "# Swedeheart R Full Export",
    "",
    "Generated by `data_analysis/scripts/00_build_full_export.R`.",
    "",
    "Main files:",
    "",
    "- `raw/health_records.csv.gz`: one row per raw health record, omitted when `--skip-raw-health-records true` is used.",
    "- `derived/daily_health_records.csv.gz`: daily deduplicated numeric health rows, omitted when `--skip-daily-health-records-gz true` is used.",
    "- `export_logs/daily_health_records_transform/daily_health_records.csv`: uncompressed daily records used for clinical alignment.",
    "- `keys_sensitive_separate/personal_id_map.csv`: direct identifier mapping.",
    "- `derived/clinical_alignment/`: clinical-aligned outputs when keys and clinical files were provided.",
    "- `manifest.json`: export counts and provenance.",
    "- `checksums.md5`: file integrity hashes."
  )
  writeLines(lines, path, useBytes = TRUE)
}

write_checksums <- function(output_dir) {
  files <- list.files(output_dir, recursive = TRUE, full.names = TRUE, all.files = TRUE, no.. = TRUE)
  files <- files[file.info(files)$isdir == FALSE]
  files <- files[basename(files) != "checksums.md5"]
  checksums <- tools::md5sum(files)
  normalized_output_dir <- normalizePath(output_dir, mustWork = TRUE)
  relative <- substring(normalizePath(files), nchar(normalized_output_dir) + 2L)
  lines <- paste(checksums, relative)
  writeLines(lines, file.path(output_dir, "checksums.md5"), useBytes = TRUE)
}

run_alignment <- function(args, output_dir, health_records_path) {
  if (is.null(args$keys) || is.null(args$clinical) || args$keys == "" || args$clinical == "") {
    return(NULL)
  }

  alignment_script <- args$alignment_script
  if (is.null(alignment_script) || alignment_script == "") {
    alignment_script <- file.path(script_dir(), "01_build_aligned_dataset.R")
  }
  if (!file.exists(alignment_script)) {
    stop(sprintf("Alignment script does not exist: %s", alignment_script), call. = FALSE)
  }

  alignment_dir <- file.path(output_dir, "derived", "clinical_alignment")
  dir.create(alignment_dir, recursive = TRUE, showWarnings = FALSE)
  command <- c(
    normalizePath(alignment_script, mustWork = TRUE),
    "--health-records", normalizePath(health_records_path, mustWork = TRUE),
    "--personal-id-map", normalizePath(
      file.path(output_dir, "keys_sensitive_separate", "personal_id_map.csv"),
      mustWork = TRUE
    ),
    "--keys", normalizePath(args$keys, mustWork = TRUE),
    "--clinical", normalizePath(args$clinical, mustWork = TRUE),
    "--output-dir", normalizePath(alignment_dir, mustWork = TRUE),
    "--clinical-sheet", args$clinical_sheet,
    "--clinical-key-col", args$clinical_key_col,
    "--clinical-heartattack-date-col", args$clinical_heartattack_date_col,
    "--clinical-heartattack-type-col", args$clinical_heartattack_type_col,
    "--clinical-physio-sheet", args$clinical_physio_sheet,
    "--clinical-physio-value-cols", args$clinical_physio_value_cols
  )
  if (!is.null(args$clinical_physio_key_col) && args$clinical_physio_key_col != "") {
    command <- c(command, "--clinical-physio-key-col", args$clinical_physio_key_col)
  }
  if (!is.null(args$window_before) && args$window_before != "") {
    command <- c(command, "--window-before", args$window_before)
  }
  if (!is.null(args$window_after) && args$window_after != "") {
    command <- c(command, "--window-after", args$window_after)
  }

  status <- system2(file.path(R.home("bin"), "Rscript"), command)
  if (!identical(status, 0L)) {
    stop("Clinical alignment failed.", call. = FALSE)
  }
  list(outputDir = alignment_dir)
}

args <- parse_args(commandArgs(trailingOnly = TRUE))
require_arg(args, "raw_data_dir")
require_arg(args, "output_dir")

raw_data_dir <- normalizePath(args$raw_data_dir, mustWork = TRUE)
users_dir <- resolve_users_dir(raw_data_dir)
output_dir <- args$output_dir
if (dir.exists(output_dir) && length(list.files(output_dir, all.files = TRUE, no.. = TRUE))) {
  stop(sprintf("Output directory is not empty: %s", output_dir), call. = FALSE)
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
output_dir <- normalizePath(output_dir, mustWork = TRUE)

for (directory in c("raw", "derived", "metadata", "keys_sensitive_separate", "export_logs")) {
  dir.create(file.path(output_dir, directory), recursive = TRUE, showWarnings = FALSE)
}

include_personal_id <- as_flag(args$include_personal_id_in_main, default = FALSE)
skip_raw_health_records <- as_flag(args$skip_raw_health_records, default = FALSE)
skip_daily_health_records_gz <- as_flag(args$skip_daily_health_records_gz, default = FALSE)
workers <- as.integer(args$workers)
if (is.na(workers) || workers < 1) {
  stop("--workers must be a positive integer.", call. = FALSE)
}
test_run <- as_flag(args$test_run, default = FALSE)
bucket_minutes <- as.integer(args$bucket_minutes)
if (is.na(bucket_minutes) || bucket_minutes < 1 || 60 %% bucket_minutes != 0) {
  stop("--bucket-minutes must be a positive divisor of 60.", call. = FALSE)
}
gzip_level <- as.integer(args$gzip_level)
if (is.na(gzip_level) || gzip_level < 0 || gzip_level > 9) {
  stop("--gzip-level must be an integer from 0 to 9.", call. = FALSE)
}
exact_interval <- as_flag(args$exact_interval, default = FALSE)
skip_alignment <- as_flag(
  args$skip_alignment,
  default = is.null(args$keys) || is.null(args$clinical) || args$keys == "" || args$clinical == ""
)

user_files <- sort(list.files(users_dir, pattern = "\\.json$", full.names = TRUE))
if (!length(user_files)) {
  stop(sprintf("No user JSON files found in %s", users_dir), call. = FALSE)
}
available_user_count <- length(user_files)
workers <- min(workers, length(user_files))
if (test_run) {
  eligible_personal_ids <- eligible_test_personal_ids(args)
  normalized_file_ids <- normalize_personal_id(tools::file_path_sans_ext(basename(user_files)))
  eligible_indices <- which(normalized_file_ids %in% eligible_personal_ids)
  if (length(eligible_indices)) {
    user_files <- user_files[eligible_indices[seq_len(min(workers, length(eligible_indices)))]]
    cat(sprintf(
      "Test run enabled: selected %d clinically matched user(s), one per configured worker when available\n",
      length(user_files)
    ))
  } else {
    user_files <- user_files[seq_len(workers)]
    cat(sprintf(
      "Test run enabled: no clinically matched test users found up front; processing first %d user(s)\n",
      length(user_files)
    ))
  }
  flush.console()
}
if (workers > 1 && !skip_raw_health_records) {
  stop("--workers > 1 currently requires --skip-raw-health-records true.", call. = FALSE)
}
if (workers > 1 && !skip_daily_health_records_gz) {
  stop("--workers > 1 currently requires --skip-daily-health-records-gz true.", call. = FALSE)
}
personal_ids <- tools::file_path_sans_ext(basename(user_files))
subject_ids <- sprintf("S%06d", seq_along(personal_ids))
subject_map <- setNames(subject_ids, personal_ids)

personal_id_map <- data.table(
  subject_id = subject_ids,
  personalId = personal_ids,
  source_file = file.path("users", basename(user_files))
)
fwrite(personal_id_map, file.path(output_dir, "keys_sensitive_separate", "personal_id_map.csv"))

raw_fields <- c(
  "subject_id",
  if (include_personal_id) "personalId",
  "record_id",
  "record_index",
  "data_type",
  "unit",
  "numeric_value",
  "value_json",
  "date_from",
  "date_to",
  "date",
  "platform_type",
  "device_id",
  "source_id",
  "source_name",
  "source_file"
)
daily_fields <- c(
  "subject_id",
  if (include_personal_id) "personalId",
  "date",
  "dataType",
  "unit",
  "value",
  "aggregation",
  "buckets",
  "sourceRecords",
  "collapsedDuplicateRecords"
)
raw_internal_drop <- c("parsed_date_from", "parsed_date_to")

raw_path <- file.path(output_dir, "raw", "health_records.csv.gz")
daily_gz_path <- file.path(output_dir, "derived", "daily_health_records.csv.gz")
daily_plain_dir <- file.path(output_dir, "export_logs", "daily_health_records_transform")
dir.create(daily_plain_dir, recursive = TRUE, showWarnings = FALSE)
daily_plain_path <- file.path(daily_plain_dir, "daily_health_records.csv")

manifest_users <- vector("list", length(user_files))
data_type_counts <- list()
raw_records_total <- 0L
numeric_records_total <- 0L
daily_rows_total <- 0L

if (workers > 1) {
  chunk_dir <- file.path(daily_plain_dir, "chunks")
  dir.create(chunk_dir, recursive = TRUE, showWarnings = FALSE)
  cat(sprintf(
    "Transforming %d users with %d worker processes\n",
    length(user_files),
    workers
  ))

  cluster <- parallel::makeCluster(workers)
  on.exit({
    try(parallel::stopCluster(cluster), silent = TRUE)
  }, add = TRUE)
  parallel::clusterEvalQ(cluster, {
    library(data.table)
    NULL
  })
  parallel::clusterExport(
    cluster,
    varlist = c(
      "user_files",
      "personal_ids",
      "subject_map",
      "include_personal_id",
      "skip_raw_health_records",
      "bucket_minutes",
      "exact_interval",
      "daily_fields",
      "csv_escape",
      "write_csv_lines",
      "parse_timestamp",
      "parse_timestamps",
      "timestamp_text",
      "floor_to_bucket",
      "json_scalar",
      "numeric_value_from_record",
      "value_json_from_record",
      "scalar_text",
      "table_character_column",
      "scalar_numeric",
      "table_numeric_column",
      "aggregation_for",
      "daily_rows_for_user",
      "empty_records_table",
      "records_for_user_fast_daily",
      "records_for_user",
      "write_daily_chunk",
      "format_duration",
      "progress_line",
      "transform_user_for_export"
    ),
    envir = environment()
  )

  daily_plain_con <- file(daily_plain_path, open = "wb")
  on.exit(try(close(daily_plain_con), silent = TRUE), add = TRUE)
  writeBin(charToRaw(paste0(paste(daily_fields, collapse = ","), "\n")), daily_plain_con)

  started_at <- Sys.time()
  completed_users <- 0L
  user_indices <- seq_along(user_files)
  batch_size <- workers * 4L
  batches <- split(user_indices, ceiling(seq_along(user_indices) / batch_size))
  cat(sprintf("Progress updates every up to %d users\n", batch_size))
  flush.console()

  for (batch in batches) {
    batch_results <- parallel::parLapplyLB(
      cluster,
      batch,
      transform_user_for_export,
      chunk_dir = chunk_dir
    )
    batch_results <- batch_results[order(vapply(batch_results, function(result) result$index, integer(1)))]

    for (result in batch_results) {
      append_file_binary(result$dailyChunk, daily_plain_con)
      raw_records_total <- raw_records_total + result$rawRecords
      numeric_records_total <- numeric_records_total + result$numericRecords
      daily_rows_total <- daily_rows_total + result$dailyRows
      data_type_counts <- merge_named_counts(data_type_counts, result$dataTypes)
      manifest_users[[result$index]] <- list(
        subject_id = result$subject_id,
        source_file = result$source_file,
        rawRecords = result$rawRecords,
        numericRecords = result$numericRecords,
        dailyRows = result$dailyRows,
        dataTypes = result$dataTypes
      )
      unlink(result$dailyChunk)
    }

    completed_users <- completed_users + length(batch_results)
    cat(progress_line(
      completed_users,
      length(user_files),
      started_at,
      raw_records_total,
      numeric_records_total,
      daily_rows_total
    ))
    flush.console()
  }

  parallel::stopCluster(cluster)
  close(daily_plain_con)
  on.exit(NULL, add = FALSE)
  unlink(chunk_dir, recursive = TRUE)
} else {
  raw_con <- NULL
  if (!skip_raw_health_records) {
    raw_con <- gzfile(raw_path, open = "wt", encoding = "UTF-8", compression = gzip_level)
  }
  daily_gz_con <- NULL
  if (!skip_daily_health_records_gz) {
    daily_gz_con <- gzfile(daily_gz_path, open = "wt", encoding = "UTF-8", compression = gzip_level)
  }
  daily_plain_con <- file(daily_plain_path, open = "wt", encoding = "UTF-8")
  on.exit({
    if (!is.null(raw_con)) {
      try(close(raw_con), silent = TRUE)
    }
    if (!is.null(daily_gz_con)) {
      try(close(daily_gz_con), silent = TRUE)
    }
    try(close(daily_plain_con), silent = TRUE)
  }, add = TRUE)

  if (!skip_raw_health_records) {
    writeLines(paste(raw_fields, collapse = ","), raw_con, useBytes = TRUE)
  }
  if (!skip_daily_health_records_gz) {
    writeLines(paste(daily_fields, collapse = ","), daily_gz_con, useBytes = TRUE)
  }
  writeLines(paste(daily_fields, collapse = ","), daily_plain_con, useBytes = TRUE)

  for (i in seq_along(user_files)) {
    path <- user_files[[i]]
    personal_id <- personal_ids[[i]]
    subject_id <- subject_map[[personal_id]]
    source_file <- file.path("users", basename(path))
    cat(sprintf("[%d/%d] Transforming %s\n", i, length(user_files), basename(path)))
    rows <- records_for_user(
      path,
      subject_id,
      personal_id,
      source_file,
      include_personal_id,
      include_raw_columns = !skip_raw_health_records
    )
    raw_records_total <- raw_records_total + nrow(rows)
    numeric_records_total <- numeric_records_total + rows[!is.na(numeric_value), .N]

    user_type_counts <- rows[data_type != "", .N, by = data_type]
    data_type_counts <- merge_named_counts(
      data_type_counts,
      as.list(setNames(user_type_counts$N, user_type_counts$data_type))
    )

    if (!skip_raw_health_records) {
      raw_output <- copy(rows)
      raw_output[, (raw_internal_drop) := NULL]
      write_csv_lines(raw_con, raw_output, raw_fields)
    }

    daily <- daily_rows_for_user(rows, bucket_minutes, exact_interval)
    if (include_personal_id && nrow(daily)) {
      daily[, personalId := personal_id]
      setcolorder(daily, daily_fields)
    }
    if (!skip_daily_health_records_gz) {
      write_csv_lines(daily_gz_con, daily, daily_fields)
    }
    write_csv_lines(daily_plain_con, daily, daily_fields)
    daily_rows_total <- daily_rows_total + nrow(daily)

    manifest_users[[i]] <- list(
      subject_id = subject_id,
      source_file = source_file,
      rawRecords = nrow(rows),
      numericRecords = rows[!is.na(numeric_value), .N],
      dailyRows = nrow(daily),
      dataTypes = as.list(setNames(user_type_counts$N, user_type_counts$data_type))
    )
  }

  if (!is.null(raw_con)) {
    close(raw_con)
  }
  if (!is.null(daily_gz_con)) {
    close(daily_gz_con)
  }
  close(daily_plain_con)
  on.exit(NULL, add = FALSE)
}

alignment_summary <- NULL
if (!skip_alignment) {
  cat("Running clinical alignment\n")
  flush.console()
  alignment_summary <- run_alignment(args, output_dir, daily_plain_path)
  cat("Clinical alignment complete\n")
  flush.console()
}

manifest <- list(
  createdAt = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS%z"),
  rawDataDir = raw_data_dir,
  usersDir = users_dir,
  outputDir = normalizePath(output_dir, mustWork = TRUE),
  includePersonalIdInMain = include_personal_id,
  skipRawHealthRecords = skip_raw_health_records,
  skipDailyHealthRecordsGz = skip_daily_health_records_gz,
  workers = workers,
  testRun = test_run,
  availableUserCount = available_user_count,
  gzipLevel = gzip_level,
  dedupeMode = if (exact_interval) "exact_interval" else "date_from_bucket",
  bucketMinutes = if (exact_interval) NULL else bucket_minutes,
  rawHealthRecords = list(
    csv = if (skip_raw_health_records) NULL else "raw/health_records.csv.gz",
    skipped = skip_raw_health_records,
    summary = list(
      userCount = length(user_files),
      rawRecords = raw_records_total,
      numericRecords = numeric_records_total,
      dataTypes = as.list(data_type_counts),
      users = manifest_users
    )
  ),
  dailyHealthRecords = list(
    csv = if (skip_daily_health_records_gz) NULL else "derived/daily_health_records.csv.gz",
    skippedGz = skip_daily_health_records_gz,
    alignmentInputCsv = "export_logs/daily_health_records_transform/daily_health_records.csv",
    dailyRows = daily_rows_total
  ),
  clinicalAlignment = alignment_summary
)

write_manifest(file.path(output_dir, "manifest.json"), manifest)
write_readme(file.path(output_dir, "README.md"))
write_checksums(output_dir)

cat(sprintf("Wrote R full export to %s\n", output_dir))
cat(sprintf("Raw records: %d across %d users\n", raw_records_total, length(user_files)))
cat(sprintf("Daily health rows: %d\n", daily_rows_total))
