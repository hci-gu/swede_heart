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
  --bucket-minutes N                   Default: 10.
  --exact-interval true|false          Default: false.
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
  raw/health_records.csv.gz
  derived/daily_health_records.csv.gz
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
    bucket_minutes = "10",
    exact_interval = "false",
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
  if (is.null(value) || is.na(value) || value == "") {
    return(as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"))
  }
  text <- sub("Z$", "", as.character(value))
  text <- sub("([+-][0-9]{2}):([0-9]{2})$", "\\1\\2", text)
  parsed <- as.POSIXct(
    text,
    tz = "UTC",
    tryFormats = c(
      "%Y-%m-%dT%H:%M:%OS%z",
      "%Y-%m-%dT%H:%M:%OS",
      "%Y-%m-%d %H:%M:%OS"
    )
  )
  parsed
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

records_for_user <- function(path, subject_id, personal_id, source_file, include_personal_id) {
  records <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  if (!is.list(records)) {
    stop(sprintf("Expected %s to contain a JSON array.", path), call. = FALSE)
  }
  if (!length(records)) {
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
    if (include_personal_id) {
      fields <- c(fields, "personalId")
    }
    empty <- data.table()
    for (field in fields) {
      empty[, (field) := character()]
    }
    empty[, numeric_value := numeric()]
    empty[, record_index := integer()]
    empty[, parsed_date_from := as.POSIXct(character(), tz = "UTC")]
    empty[, parsed_date_to := as.POSIXct(character(), tz = "UTC")]
    return(empty)
  }

  rows <- vector("list", length(records))
  for (index in seq_along(records)) {
    record <- records[[index]]
    if (!is.list(record)) {
      date_from <- ""
      date_to <- ""
      parsed_date_from <- as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC")
      parsed_date_to <- as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC")
      row <- list(
        subject_id = subject_id,
        record_id = sprintf("%s:%08d", subject_id, index),
        record_index = index,
        data_type = "",
        unit = "",
        numeric_value = NA_real_,
        value_json = jsonlite::toJSON(record, auto_unbox = TRUE, null = "null", digits = NA),
        date_from = date_from,
        date_to = date_to,
        date = "",
        platform_type = "",
        device_id = "",
        source_id = "",
        source_name = "",
        source_file = source_file,
        parsed_date_from = parsed_date_from,
        parsed_date_to = parsed_date_to
      )
    } else {
      date_from <- json_scalar(record, "date_from")
      date_to <- json_scalar(record, "date_to")
      parsed_date_from <- parse_timestamp(date_from)
      parsed_date_to <- parse_timestamp(date_to)
      row <- list(
        subject_id = subject_id,
        record_id = sprintf("%s:%08d", subject_id, index),
        record_index = index,
        data_type = json_scalar(record, "data_type"),
        unit = json_scalar(record, "unit"),
        numeric_value = numeric_value_from_record(record),
        value_json = value_json_from_record(record),
        date_from = date_from,
        date_to = date_to,
        date = if (nchar(date_from) >= 10) substr(date_from, 1, 10) else "",
        platform_type = json_scalar(record, "platform_type"),
        device_id = json_scalar(record, "device_id"),
        source_id = json_scalar(record, "source_id"),
        source_name = json_scalar(record, "source_name"),
        source_file = source_file,
        parsed_date_from = parsed_date_from,
        parsed_date_to = parsed_date_to
      )
    }
    if (include_personal_id) {
      row$personalId <- personal_id
    }
    rows[[index]] <- row
  }

  rbindlist(rows, use.names = TRUE, fill = TRUE)
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
    "- `raw/health_records.csv.gz`: one row per raw health record.",
    "- `derived/daily_health_records.csv.gz`: daily deduplicated numeric health rows.",
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
    "--keys", normalizePath(args$keys, mustWork = TRUE),
    "--clinical", normalizePath(args$clinical, mustWork = TRUE),
    "--output-dir", normalizePath(alignment_dir, mustWork = TRUE),
    "--clinical-sheet", args$clinical_sheet,
    "--clinical-key-col", args$clinical_key_col,
    "--clinical-heartattack-date-col", args$clinical_heartattack_date_col,
    "--clinical-heartattack-type-col", args$clinical_heartattack_type_col,
    "--clinical-physio-sheet", args$clinical_physio_sheet,
    "--clinical-physio-key-col", args$clinical_physio_key_col,
    "--clinical-physio-value-cols", args$clinical_physio_value_cols
  )
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

for (directory in c("raw", "derived", "metadata", "keys_sensitive_separate", "export_logs")) {
  dir.create(file.path(output_dir, directory), recursive = TRUE, showWarnings = FALSE)
}

include_personal_id <- as_flag(args$include_personal_id_in_main, default = FALSE)
bucket_minutes <- as.integer(args$bucket_minutes)
if (is.na(bucket_minutes) || bucket_minutes < 1 || 60 %% bucket_minutes != 0) {
  stop("--bucket-minutes must be a positive divisor of 60.", call. = FALSE)
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

raw_con <- gzfile(raw_path, open = "wt", encoding = "UTF-8")
daily_gz_con <- gzfile(daily_gz_path, open = "wt", encoding = "UTF-8")
daily_plain_con <- file(daily_plain_path, open = "wt", encoding = "UTF-8")
on.exit({
  try(close(raw_con), silent = TRUE)
  try(close(daily_gz_con), silent = TRUE)
  try(close(daily_plain_con), silent = TRUE)
}, add = TRUE)

writeLines(paste(raw_fields, collapse = ","), raw_con, useBytes = TRUE)
writeLines(paste(daily_fields, collapse = ","), daily_gz_con, useBytes = TRUE)
writeLines(paste(daily_fields, collapse = ","), daily_plain_con, useBytes = TRUE)

manifest_users <- vector("list", length(user_files))
data_type_counts <- list()
raw_records_total <- 0L
numeric_records_total <- 0L
daily_rows_total <- 0L

for (i in seq_along(user_files)) {
  path <- user_files[[i]]
  personal_id <- personal_ids[[i]]
  subject_id <- subject_map[[personal_id]]
  source_file <- file.path("users", basename(path))
  cat(sprintf("[%d/%d] Transforming %s\n", i, length(user_files), basename(path)))
  rows <- records_for_user(path, subject_id, personal_id, source_file, include_personal_id)
  raw_records_total <- raw_records_total + nrow(rows)
  numeric_records_total <- numeric_records_total + rows[!is.na(numeric_value), .N]

  user_type_counts <- rows[data_type != "", .N, by = data_type]
  if (nrow(user_type_counts)) {
    for (row_index in seq_len(nrow(user_type_counts))) {
      name <- user_type_counts$data_type[[row_index]]
      current_count <- data_type_counts[[name]]
      if (is.null(current_count)) {
        current_count <- 0L
      }
      data_type_counts[[name]] <- current_count + user_type_counts$N[[row_index]]
    }
  }

  raw_output <- copy(rows)
  raw_output[, (raw_internal_drop) := NULL]
  write_csv_lines(raw_con, raw_output, raw_fields)

  daily <- daily_rows_for_user(rows, bucket_minutes, exact_interval)
  if (include_personal_id && nrow(daily)) {
    daily[, personalId := personal_id]
    setcolorder(daily, daily_fields)
  }
  write_csv_lines(daily_gz_con, daily, daily_fields)
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

close(raw_con)
close(daily_gz_con)
close(daily_plain_con)
on.exit(NULL, add = FALSE)

alignment_summary <- NULL
if (!skip_alignment) {
  alignment_summary <- run_alignment(args, output_dir, daily_plain_path)
}

manifest <- list(
  createdAt = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS%z"),
  rawDataDir = raw_data_dir,
  usersDir = users_dir,
  outputDir = normalizePath(output_dir, mustWork = TRUE),
  includePersonalIdInMain = include_personal_id,
  dedupeMode = if (exact_interval) "exact_interval" else "date_from_bucket",
  bucketMinutes = if (exact_interval) NULL else bucket_minutes,
  rawHealthRecords = list(
    csv = "raw/health_records.csv.gz",
    summary = list(
      userCount = length(user_files),
      rawRecords = raw_records_total,
      numericRecords = numeric_records_total,
      dataTypes = as.list(data_type_counts),
      users = manifest_users
    )
  ),
  dailyHealthRecords = list(
    csv = "derived/daily_health_records.csv.gz",
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
