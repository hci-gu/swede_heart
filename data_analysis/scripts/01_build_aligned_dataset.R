#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  if (!requireNamespace("data.table", quietly = TRUE)) {
    stop(
      "Package 'data.table' is required. Install it before running this script.",
      call. = FALSE
    )
  }
})

library(data.table)

usage <- function() {
  cat("
Build heart-attack-aligned datasets from health records, key mapping, and clinical data.

Required:
  --health-records PATH
  --keys PATH                           CSV/XLSX. XLSX uses column A=key, B=personalId.
  --clinical PATH                       CSV/XLSX. XLSX defaults to sheet RiksHia.

Optional:
  --output-dir PATH                       default: derived
  --health-personal-id-col NAME           default: personalId
  --key-personal-id-col NAME              default: personalId, CSV only
  --key-id-col NAME                       default: key, CSV only
  --clinical-personal-id-col NAME         default: personalId
  --clinical-sheet NAME                   default: RiksHia, Excel only
  --clinical-heartattack-date-col NAME    default: P
  --clinical-heartattack-type-col NAME    default: GJ
  --window-before DAYS                    default: no lower bound
  --window-after DAYS                     default: no upper bound
  --help

Outputs:
  subject_index.csv
  health_records_aligned.csv
  daily_features_aligned.csv
")
}

parse_args <- function(args) {
  result <- list(
    output_dir = "derived",
    health_personal_id_col = "personalId",
    key_personal_id_col = "personalId",
    key_id_col = "key",
    clinical_personal_id_col = "personalId",
    clinical_sheet = "RiksHia",
    clinical_heartattack_date_col = "P",
    clinical_heartattack_type_col = "GJ",
    window_before = NA_integer_,
    window_after = NA_integer_
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

require_col <- function(data, col, label) {
  if (!col %in% names(data)) {
    stop(
      sprintf(
        "%s is missing required column '%s'. Available columns: %s",
        label,
        col,
        paste(names(data), collapse = ", ")
      ),
      call. = FALSE
    )
  }
}

optional_col <- function(data, col) {
  if (col %in% names(data)) col else NULL
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

select_excel_or_named_col <- function(data, selector, label) {
  if (selector %in% names(data)) {
    return(data[[selector]])
  }

  if (is_excel_column_ref(selector)) {
    index <- excel_column_index(selector)
    if (index > ncol(data)) {
      stop(
        sprintf(
          "%s column '%s' resolves to index %s, but the file has only %s columns.",
          label,
          selector,
          index,
          ncol(data)
        ),
        call. = FALSE
      )
    }
    return(data[[index]])
  }

  require_col(data, selector, label)
  data[[selector]]
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

is_valid_personal_id <- function(value) {
  !is.na(value) & grepl("^[0-9]{8}-[0-9]{4}$", value)
}

read_key_table <- function(path, key_id_col, key_personal_id_col) {
  extension <- tolower(tools::file_ext(path))

  if (extension %in% c("xlsx", "xls")) {
    if (!requireNamespace("readxl", quietly = TRUE)) {
      stop(
        "Package 'readxl' is required to read Excel key files. ",
        "Install it before running this script, or provide the keys as CSV.",
        call. = FALSE
      )
    }

    keys <- as.data.table(readxl::read_excel(path, col_names = FALSE))
    if (ncol(keys) < 2) {
      stop("Excel key file must have ID in column A and personalId in column B.", call. = FALSE)
    }
    setnames(keys, paste0("col", seq_len(ncol(keys))))
    keys <- keys[, .(key = as.character(col1), personalId = as.character(col2))]
  } else {
    keys <- fread(path)
    require_col(keys, key_personal_id_col, "keys")
    key_col <- optional_col(keys, key_id_col)

    if (is.null(key_col)) {
      keys <- keys[, .(key = NA_character_, personalId = as.character(get(key_personal_id_col)))]
    } else {
      keys <- keys[
        ,
        .(
          key = as.character(get(key_col)),
          personalId = as.character(get(key_personal_id_col))
        )
      ]
    }
  }

  keys[, personalId := normalize_personal_id(personalId)]
  keys <- keys[is_valid_personal_id(personalId)]
  if (!nrow(keys)) {
    stop("No valid personal IDs found in key file.", call. = FALSE)
  }
  unique(keys)
}

read_clinical_table <- function(
  path,
  clinical_sheet,
  personal_id_col,
  heartattack_date_col,
  heartattack_type_col
) {
  extension <- tolower(tools::file_ext(path))

  if (extension %in% c("xlsx", "xls")) {
    if (!requireNamespace("readxl", quietly = TRUE)) {
      stop(
        "Package 'readxl' is required to read Excel clinical files. ",
        "Install it before running this script, or provide the clinical data as CSV.",
        call. = FALSE
      )
    }

    clinical_raw <- as.data.table(
      readxl::read_excel(path, sheet = clinical_sheet, col_names = TRUE)
    )
    return(data.table(
      personalId = as.character(select_excel_or_named_col(
        clinical_raw,
        personal_id_col,
        "clinical personal ID"
      )),
      heartattack_date = select_excel_or_named_col(
        clinical_raw,
        heartattack_date_col,
        "clinical heart attack date"
      ),
      heartattack_type = as.character(select_excel_or_named_col(
        clinical_raw,
        heartattack_type_col,
        "clinical heart attack type"
      ))
    ))
  }

  clinical <- fread(path)
  require_col(clinical, personal_id_col, "clinical data")
  require_col(clinical, heartattack_date_col, "clinical data")

  type_col <- optional_col(clinical, heartattack_type_col)
  if (is.null(type_col)) {
    clinical[
      ,
      .(
        personalId = as.character(get(personal_id_col)),
        heartattack_date = get(heartattack_date_col),
        heartattack_type = NA_character_
      )
    ]
  } else {
    clinical[
      ,
      .(
        personalId = as.character(get(personal_id_col)),
        heartattack_date = get(heartattack_date_col),
        heartattack_type = as.character(get(type_col))
      )
    ]
  }
}

parse_days <- function(value, label) {
  if (is.null(value) || is.na(value) || value == "") {
    return(NA_integer_)
  }
  parsed <- suppressWarnings(as.integer(value))
  if (is.na(parsed) || parsed < 0) {
    stop(sprintf("%s must be a non-negative integer", label), call. = FALSE)
  }
  parsed
}

date_component <- function(value) {
  value <- trimws(as.character(value))
  fifelse(nchar(value) >= 10, substr(value, 1, 10), value)
}

to_idate <- function(value, label) {
  if (inherits(value, "Date") || inherits(value, "POSIXt")) {
    parsed <- as.IDate(value)
  } else if (is.numeric(value)) {
    parsed <- as.IDate(as.Date(value, origin = "1899-12-30"))
  } else {
    parsed <- as.IDate(date_component(value))
  }
  if (all(is.na(parsed)) && any(!is.na(value) & value != "")) {
    stop(sprintf("Could not parse dates in %s", label), call. = FALSE)
  }
  parsed
}

first_non_missing_date <- function(value) {
  value <- value[!is.na(value)]
  if (!length(value)) {
    return(as.IDate(NA))
  }
  min(value)
}

write_csv <- function(data, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  fwrite(data, path, na = "")
}

args <- parse_args(commandArgs(trailingOnly = TRUE))
require_arg(args, "health_records")
require_arg(args, "keys")
require_arg(args, "clinical")

window_before <- parse_days(args$window_before, "--window-before")
window_after <- parse_days(args$window_after, "--window-after")

message("Reading health records: ", args$health_records)
health <- fread(args$health_records)
message("Reading keys: ", args$keys)
keys <- read_key_table(args$keys, args$key_id_col, args$key_personal_id_col)
message("Reading clinical data: ", args$clinical)
clinical <- read_clinical_table(
  args$clinical,
  args$clinical_sheet,
  args$clinical_personal_id_col,
  args$clinical_heartattack_date_col,
  args$clinical_heartattack_type_col
)

require_col(health, args$health_personal_id_col, "health records")
require_col(health, "date", "health records")
require_col(health, "dataType", "health records")
require_col(health, "numericValue", "health records")

setnames(health, args$health_personal_id_col, "personalId")

health[, personalId := normalize_personal_id(personalId)]
clinical[, personalId := normalize_personal_id(personalId)]
health <- health[is_valid_personal_id(personalId)]
clinical <- clinical[is_valid_personal_id(personalId)]

clinical[, heartattack_date := to_idate(heartattack_date, "clinical heart attack date")]
clinical[, heartattack_type := trimws(as.character(heartattack_type))]
clinical[heartattack_type == "", heartattack_type := NA_character_]
clinical_events <- clinical[
  !is.na(heartattack_date),
  .(heartattack_date, heartattack_type),
  by = personalId
]
setorder(clinical_events, personalId, heartattack_date)
heartattack_events <- clinical_events[, .SD[1], by = personalId]

subject_index <- merge(keys, heartattack_events, by = "personalId", all.x = TRUE)
setorder(subject_index, personalId)
subject_index[, subject_id := sprintf("S%06d", .I)]
subject_index[
  ,
  `:=`(
    heartattack_source = fifelse(
      is.na(heartattack_date),
      NA_character_,
      "clinical"
    ),
    include_reason = fifelse(
      is.na(heartattack_date),
      NA_character_,
      "has_heartattack_date"
    ),
    exclude_reason = fifelse(
      is.na(heartattack_date),
      "missing_heartattack_date",
      NA_character_
    )
  )
]

subject_index <- subject_index[
  ,
  .(
    subject_id,
    personalId,
    key,
    heartattack_date,
    heartattack_type,
    heartattack_source,
    include_reason,
    exclude_reason
  )
]

included_subjects <- subject_index[!is.na(heartattack_date)]

health[, record_date := to_idate(date, "health record date")]
aligned <- merge(
  health,
  included_subjects[, .(subject_id, personalId, heartattack_date, heartattack_type)],
  by = "personalId",
  all = FALSE,
  allow.cartesian = FALSE
)
aligned[, relative_day := as.integer(record_date - heartattack_date)]

if (!is.na(window_before)) {
  aligned <- aligned[relative_day >= -window_before]
}
if (!is.na(window_after)) {
  aligned <- aligned[relative_day <= window_after]
}

setcolorder(
  aligned,
  c(
    "subject_id",
    "personalId",
    "heartattack_date",
    "heartattack_type",
    "record_date",
    "relative_day",
    setdiff(names(aligned), c(
      "subject_id",
      "personalId",
      "heartattack_date",
      "heartattack_type",
      "record_date",
      "relative_day"
    ))
  )
)
setorder(aligned, subject_id, relative_day, dateFrom, dataType)

daily_counts <- aligned[
  ,
  .(
    record_count = .N,
    data_type_count = uniqueN(dataType)
  ),
  by = .(subject_id, relative_day)
]

aligned[, numeric_value := suppressWarnings(as.numeric(numericValue))]

safe_mean <- function(value) {
  value <- value[!is.na(value)]
  if (!length(value)) NA_real_ else mean(value)
}

safe_median <- function(value) {
  value <- value[!is.na(value)]
  if (!length(value)) NA_real_ else median(value)
}

daily_steps <- aligned[
  dataType == "STEPS",
  .(
    steps_sum = sum(numeric_value, na.rm = TRUE),
    steps_records = .N
  ),
  by = .(subject_id, relative_day)
]

daily_walking_speed <- aligned[
  dataType == "WALKING_SPEED",
  .(
    walking_speed_mean = safe_mean(numeric_value),
    walking_speed_median = safe_median(numeric_value),
    walking_speed_records = .N
  ),
  by = .(subject_id, relative_day)
]

daily_walking_asymmetry <- aligned[
  dataType == "WALKING_ASYMMETRY_PERCENTAGE",
  .(
    walking_asymmetry_mean = safe_mean(numeric_value),
    walking_asymmetry_median = safe_median(numeric_value),
    walking_asymmetry_records = .N
  ),
  by = .(subject_id, relative_day)
]

daily_features <- Reduce(
  function(left, right) merge(left, right, by = c("subject_id", "relative_day"), all = TRUE),
  list(daily_counts, daily_steps, daily_walking_speed, daily_walking_asymmetry)
)

daily_features <- merge(
  included_subjects[, .(subject_id, personalId, heartattack_date, heartattack_type)],
  daily_features,
  by = "subject_id",
  all.y = TRUE
)
setorder(daily_features, subject_id, relative_day)
aligned[, numeric_value := NULL]

output_dir <- args$output_dir
subject_index_path <- file.path(output_dir, "subject_index.csv")
aligned_path <- file.path(output_dir, "health_records_aligned.csv")
daily_features_path <- file.path(output_dir, "daily_features_aligned.csv")

write_csv(subject_index, subject_index_path)
write_csv(aligned, aligned_path)
write_csv(daily_features, daily_features_path)

message("Wrote subject index: ", subject_index_path)
message("Wrote aligned health records: ", aligned_path)
message("Wrote daily features: ", daily_features_path)
message("Subjects: ", nrow(subject_index))
message("Subjects with heart attack date: ", nrow(included_subjects))
message("Aligned health records: ", nrow(aligned))
message("Daily feature rows: ", nrow(daily_features))
