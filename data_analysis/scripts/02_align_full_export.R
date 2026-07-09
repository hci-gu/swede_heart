#!/usr/bin/env Rscript

usage <- function() {
  cat("
Align a prepared Swedeheart full export with key and clinical files.

This is an R-only remote-machine wrapper for exports prepared locally with:

  python3 scripts/build_full_export.py RAW_DIR --output-dir EXPORT_DIR --skip-alignment

Required:
  --export-dir PATH
  --keys PATH                           CSV/XLSX. XLSX uses column A=key, B=personalId.
  --clinical PATH                       CSV/XLSX. XLSX defaults to sheet RiksHia.

Optional:
  --health-records PATH                 default: EXPORT_DIR/export_logs/daily_health_records_transform/daily_health_records.csv
  --personal-id-map PATH                default: EXPORT_DIR/keys_sensitive_separate/personal_id_map.csv
  --output-dir PATH                     default: EXPORT_DIR/derived/clinical_alignment
  --script PATH                         default: data_analysis/scripts/01_build_aligned_dataset.R next to this script
  --clinical-sheet NAME                 default: RiksHia
  --clinical-key-col NAME               default: pseudo_PNR
  --clinical-heartattack-date-col NAME  default: P
  --clinical-heartattack-type-col NAME  default: GJ
  --clinical-physio-sheet NAME          default: Physio
  --clinical-physio-key-col NAME        default: --clinical-key-col
  --clinical-physio-value-cols COLS     default: E,F,G
  --window-before DAYS
  --window-after DAYS
  --help

Outputs are created by 01_build_aligned_dataset.R:
  subject_index.csv
  health_records_aligned.csv
  daily_features_aligned.csv
")
}

parse_args <- function(args) {
  result <- list(
    export_dir = NULL,
    keys = NULL,
    clinical = NULL,
    health_records = NULL,
    personal_id_map = NULL,
    output_dir = NULL,
    script = NULL,
    clinical_sheet = "RiksHia",
    clinical_key_col = "pseudo_PNR",
    clinical_heartattack_date_col = "P",
    clinical_heartattack_type_col = "GJ",
    clinical_physio_sheet = "Physio",
    clinical_physio_key_col = "",
    clinical_physio_value_cols = "E,F,G",
    window_before = NULL,
    window_after = NULL
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

require_arg <- function(args, name) {
  if (is.null(args[[name]]) || is.na(args[[name]]) || args[[name]] == "") {
    stop(sprintf("Missing required argument --%s", gsub("_", "-", name)), call. = FALSE)
  }
}

require_file <- function(path, label) {
  if (!file.exists(path)) {
    stop(sprintf("%s does not exist: %s", label, path), call. = FALSE)
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

args <- parse_args(commandArgs(trailingOnly = TRUE))
require_arg(args, "export_dir")
require_arg(args, "keys")
require_arg(args, "clinical")

export_dir <- normalizePath(args$export_dir, mustWork = TRUE)
health_records <- args$health_records
if (is.null(health_records) || health_records == "") {
  health_records <- file.path(
    export_dir,
    "export_logs",
    "daily_health_records_transform",
    "daily_health_records.csv"
  )
}
personal_id_map <- args$personal_id_map
if (is.null(personal_id_map) || personal_id_map == "") {
  personal_id_map <- file.path(export_dir, "keys_sensitive_separate", "personal_id_map.csv")
}

output_dir <- args$output_dir
if (is.null(output_dir) || output_dir == "") {
  output_dir <- file.path(export_dir, "derived", "clinical_alignment")
}

alignment_script <- args$script
if (is.null(alignment_script) || alignment_script == "") {
  alignment_script <- file.path(script_dir(), "01_build_aligned_dataset.R")
}

require_file(health_records, "Health records input")
require_file(personal_id_map, "Personal ID map")
require_file(args$keys, "Key file")
require_file(args$clinical, "Clinical file")
require_file(alignment_script, "Alignment script")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

command <- c(
  normalizePath(alignment_script, mustWork = TRUE),
  "--health-records", normalizePath(health_records, mustWork = TRUE),
  "--personal-id-map", normalizePath(personal_id_map, mustWork = TRUE),
  "--keys", normalizePath(args$keys, mustWork = TRUE),
  "--clinical", normalizePath(args$clinical, mustWork = TRUE),
  "--output-dir", normalizePath(output_dir, mustWork = TRUE),
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

cat("Running clinical alignment:\n")
cat("Rscript", paste(shQuote(command), collapse = " "), "\n")

status <- system2(file.path(R.home("bin"), "Rscript"), command)
if (!identical(status, 0L)) {
  quit(status = status)
}

cat("Clinical alignment outputs written to: ", output_dir, "\n", sep = "")
