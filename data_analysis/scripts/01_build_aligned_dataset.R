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
  --personal-id-map PATH                  optional subject_id -> personalId map
  --health-value-col NAME                 default: auto, uses numericValue or value
  --key-personal-id-col NAME              default: personalId, CSV only
  --key-id-col NAME                       default: key, CSV only
  --clinical-key-col NAME                 default: pseudo_PNR
  --clinical-sheet NAME                   default: RiksHia, Excel only
  --clinical-heartattack-date-col NAME    default: P
  --clinical-heartattack-type-col NAME    default: GJ
  --clinical-physio-sheet NAME            default: Physio
  --clinical-physio-key-col NAME          default: --clinical-key-col
  --clinical-physio-value-cols COLS       default: E,F,G
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
    personal_id_map = NULL,
    health_value_col = "auto",
    key_personal_id_col = "personalId",
    key_id_col = "key",
    clinical_key_col = "pseudo_PNR",
    clinical_sheet = "RiksHia",
    clinical_heartattack_date_col = "P",
    clinical_heartattack_type_col = "GJ",
    clinical_physio_sheet = "Physio",
    clinical_physio_key_col = "",
    clinical_physio_value_cols = "E,F,G",
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

resolve_named_col <- function(data, col, label) {
  if (col %in% names(data)) {
    return(col)
  }

  prefixed <- names(data)[startsWith(names(data), paste0(col, " "))]
  if (length(prefixed) == 1L) {
    return(prefixed[[1]])
  }
  if (length(prefixed) > 1L) {
    stop(
      sprintf(
        "%s column '%s' matched multiple columns: %s",
        label,
        col,
        paste(prefixed, collapse = ", ")
      ),
      call. = FALSE
    )
  }

  require_col(data, col, label)
  col
}

resolve_health_value_col <- function(data, requested_col) {
  if (!is.null(requested_col) && requested_col != "" && requested_col != "auto") {
    require_col(data, requested_col, "health records")
    return(requested_col)
  }

  for (candidate in c("numericValue", "value")) {
    if (candidate %in% names(data)) {
      return(candidate)
    }
  }

  stop(
    sprintf(
      "health records is missing a numeric value column. Expected one of: numericValue, value. Available columns: %s",
      paste(names(data), collapse = ", ")
    ),
    call. = FALSE
  )
}

add_personal_id_from_map <- function(health, personal_id_map_path, health_personal_id_col) {
  if (health_personal_id_col %in% names(health)) {
    return(list(health = health, health_personal_id_col = health_personal_id_col))
  }
  if (!"subject_id" %in% names(health) || is.null(personal_id_map_path) || personal_id_map_path == "") {
    return(list(health = health, health_personal_id_col = health_personal_id_col))
  }
  if (!file.exists(personal_id_map_path)) {
    stop(sprintf("--personal-id-map does not exist: %s", personal_id_map_path), call. = FALSE)
  }

  message("Mapping health subject_id to personalId using: ", personal_id_map_path)
  id_map <- fread(personal_id_map_path)
  require_col(id_map, "subject_id", "personal ID map")
  require_col(id_map, "personalId", "personal ID map")
  id_map <- unique(id_map[, .(subject_id, personalId)])
  health <- merge(health, id_map, by = "subject_id", all.x = TRUE, sort = FALSE)
  setnames(health, "subject_id", "source_subject_id")
  list(health = health, health_personal_id_col = "personalId")
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

  if (!is_excel_column_ref(selector)) {
    resolved <- resolve_named_col(data, selector, label)
    return(data[[resolved]])
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

  resolved <- resolve_named_col(data, selector, label)
  data[[resolved]]
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

personal_id_birth_date <- function(personal_id) {
  digits <- gsub("[^0-9]", "", as.character(personal_id))
  birth_text <- fifelse(
    !is.na(digits) & nchar(digits) >= 8,
    paste0(substr(digits, 1, 4), "-", substr(digits, 5, 6), "-", substr(digits, 7, 8)),
    NA_character_
  )
  as.IDate(birth_text)
}

personal_id_gender <- function(personal_id) {
  digits <- gsub("[^0-9]", "", as.character(personal_id))
  gender_digit <- suppressWarnings(as.integer(substr(digits, 11, 11)))
  fifelse(
    is.na(gender_digit),
    NA_character_,
    fifelse(gender_digit %% 2L == 1L, "male", "female")
  )
}

age_at_date <- function(birth_date, reference_date) {
  birth_date <- as.IDate(birth_date)
  reference_date <- as.IDate(reference_date)
  age <- as.integer(format(reference_date, "%Y")) - as.integer(format(birth_date, "%Y"))
  had_birthday <- format(reference_date, "%m%d") >= format(birth_date, "%m%d")
  needs_subtract <- !is.na(had_birthday) & !had_birthday
  age[needs_subtract] <- age[needs_subtract] - 1L
  age[is.na(birth_date) | is.na(reference_date)] <- NA_integer_
  age
}

normalize_key <- function(value) {
  normalized <- trimws(as.character(value))
  normalized[normalized == ""] <- NA_character_
  normalized
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

    keys <- as.data.table(suppressMessages(
      readxl::read_excel(path, col_names = FALSE)
    ))
    if (ncol(keys) < 2) {
      stop("Excel key file must have ID in column A and personalId in column B.", call. = FALSE)
    }
    setnames(keys, paste0("col", seq_len(ncol(keys))))
    keys <- keys[, .(pseudo_PNR = as.character(col1), personalId = as.character(col2))]
  } else {
    keys <- fread(path)
    require_col(keys, key_personal_id_col, "keys")
    key_col <- optional_col(keys, key_id_col)

    if (is.null(key_col)) {
      keys <- keys[
        ,
        .(
          pseudo_PNR = NA_character_,
          personalId = as.character(get(key_personal_id_col))
        )
      ]
    } else {
      keys <- keys[
        ,
        .(
          pseudo_PNR = as.character(get(key_col)),
          personalId = as.character(get(key_personal_id_col))
        )
      ]
    }
  }

  keys[, pseudo_PNR := normalize_key(pseudo_PNR)]
  keys[, personalId := normalize_personal_id(personalId)]
  keys <- keys[!is.na(pseudo_PNR) & is_valid_personal_id(personalId)]
  if (!nrow(keys)) {
    stop("No valid pseudo_PNR/personalId rows found in key file.", call. = FALSE)
  }
  unique(keys)
}

read_clinical_table <- function(
  path,
  clinical_sheet,
  clinical_key_col,
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

    clinical_raw <- as.data.table(suppressMessages(
      readxl::read_excel(path, sheet = clinical_sheet, col_names = TRUE)
    ))
    return(data.table(
      pseudo_PNR = normalize_key(select_excel_or_named_col(
        clinical_raw,
        clinical_key_col,
        "clinical key"
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
  clinical_key_col <- resolve_named_col(clinical, clinical_key_col, "clinical data")
  heartattack_date_col <- resolve_named_col(clinical, heartattack_date_col, "clinical data")

  type_col <- optional_col(clinical, heartattack_type_col)
  if (is.null(type_col) && !is_excel_column_ref(heartattack_type_col)) {
    type_col <- resolve_named_col(clinical, heartattack_type_col, "clinical data")
  }
  if (is.null(type_col)) {
    clinical[
      ,
      .(
        pseudo_PNR = normalize_key(get(clinical_key_col)),
        heartattack_date = get(heartattack_date_col),
        heartattack_type = NA_character_
      )
    ]
  } else {
    clinical[
      ,
      .(
        pseudo_PNR = normalize_key(get(clinical_key_col)),
        heartattack_date = get(heartattack_date_col),
        heartattack_type = as.character(get(type_col))
      )
    ]
  }
}

split_column_selectors <- function(value) {
  selectors <- trimws(strsplit(as.character(value), ",", fixed = TRUE)[[1]])
  selectors[selectors != ""]
}

physio_value_to_flag <- function(value) {
  normalized <- tolower(trimws(as.character(value)))
  normalized[is.na(normalized)] <- ""
  fifelse(
    normalized == "ja",
    TRUE,
    fifelse(normalized == "nej", FALSE, NA)
  )
}

read_physio_table <- function(
  path,
  clinical_sheet,
  clinical_key_col,
  physio_sheet,
  physio_key_col,
  physio_value_cols
) {
  extension <- tolower(tools::file_ext(path))
  key_col <- physio_key_col
  if (is.null(key_col) || is.na(key_col) || key_col == "") {
    key_col <- clinical_key_col
  }
  value_cols <- split_column_selectors(physio_value_cols)
  if (!length(value_cols)) {
    stop("--clinical-physio-value-cols must include at least one column.", call. = FALSE)
  }

  if (extension %in% c("xlsx", "xls")) {
    if (!requireNamespace("readxl", quietly = TRUE)) {
      stop(
        "Package 'readxl' is required to read Excel Physio sheets. ",
        "Install it before running this script, or provide the clinical data as CSV.",
        call. = FALSE
      )
    }

    physio_raw <- as.data.table(suppressMessages(
      readxl::read_excel(path, sheet = physio_sheet, col_names = TRUE)
    ))
  } else {
    physio_raw <- fread(path)
  }

  physio <- data.table(
    pseudo_PNR = normalize_key(select_excel_or_named_col(
      physio_raw,
      key_col,
      "clinical physio key"
    ))
  )

  for (index in seq_along(value_cols)) {
    selector <- value_cols[[index]]
    physio[
      ,
      paste0("physio_value_", index) := physio_value_to_flag(
        select_excel_or_named_col(
          physio_raw,
          selector,
          "clinical physio value"
        )
      )
    ]
  }

  value_names <- paste0("physio_value_", seq_along(value_cols))
  physio[
    ,
    has_received_physiotherapy := apply(
      .SD,
      1,
      function(values) {
        values <- as.logical(values)
        if (any(values %in% TRUE, na.rm = TRUE)) {
          TRUE
        } else if (any(values %in% FALSE, na.rm = TRUE)) {
          FALSE
        } else {
          NA
        }
      }
    ),
    .SDcols = value_names
  ]

  physio <- physio[
    !is.na(pseudo_PNR),
    .(
      has_received_physiotherapy = if (any(has_received_physiotherapy %in% TRUE, na.rm = TRUE)) {
        TRUE
      } else if (any(has_received_physiotherapy %in% FALSE, na.rm = TRUE)) {
        FALSE
      } else {
        NA
      }
    ),
    by = "pseudo_PNR"
  ]
  physio
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

setorder_existing <- function(data, columns) {
  existing_columns <- columns[columns %in% names(data)]
  if (length(existing_columns)) {
    setorderv(data, existing_columns)
  }
}

args <- parse_args(commandArgs(trailingOnly = TRUE))
require_arg(args, "health_records")
require_arg(args, "keys")
require_arg(args, "clinical")
if (!is.null(args$clinical_personal_id_col)) {
  args$clinical_key_col <- args$clinical_personal_id_col
}

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
  args$clinical_key_col,
  args$clinical_heartattack_date_col,
  args$clinical_heartattack_type_col
)
physio <- read_physio_table(
  args$clinical,
  args$clinical_sheet,
  args$clinical_key_col,
  args$clinical_physio_sheet,
  args$clinical_physio_key_col,
  args$clinical_physio_value_cols
)

mapped_health <- add_personal_id_from_map(health, args$personal_id_map, args$health_personal_id_col)
health <- mapped_health$health
args$health_personal_id_col <- mapped_health$health_personal_id_col

require_col(health, args$health_personal_id_col, "health records")
require_col(health, "date", "health records")
require_col(health, "dataType", "health records")
health_value_col <- resolve_health_value_col(health, args$health_value_col)

setnames(health, args$health_personal_id_col, "personalId")
if (health_value_col != "numericValue") {
  health[, numericValue := get(health_value_col)]
}

health[, personalId := normalize_personal_id(personalId)]
health <- health[is_valid_personal_id(personalId)]
clinical <- clinical[!is.na(pseudo_PNR)]

clinical[, heartattack_date := to_idate(heartattack_date, "clinical heart attack date")]
clinical[, heartattack_type := trimws(as.character(heartattack_type))]
clinical[heartattack_type == "", heartattack_type := NA_character_]
clinical_events <- clinical[
  !is.na(heartattack_date),
  .(heartattack_date, heartattack_type),
  by = "pseudo_PNR"
]
setorderv(clinical_events, c("pseudo_PNR", "heartattack_date"))
heartattack_events <- clinical_events[, .SD[1], by = "pseudo_PNR"]

subject_index <- merge(keys, heartattack_events, by = "pseudo_PNR", all.x = TRUE)
subject_index <- merge(subject_index, physio, by = "pseudo_PNR", all.x = TRUE)
setorder(subject_index, personalId)
subject_index[, subject_id := sprintf("S%06d", .I)]
subject_index[
  ,
  `:=`(
    birth_date = personal_id_birth_date(personalId),
    gender = personal_id_gender(personalId)
  )
]
subject_index[, age := age_at_date(birth_date, heartattack_date)]
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
    pseudo_PNR,
    birth_date,
    gender,
    age,
    heartattack_date,
    heartattack_type,
    has_received_physiotherapy,
    heartattack_source,
    include_reason,
    exclude_reason
  )
]

included_subjects <- subject_index[!is.na(heartattack_date)]

health[, record_date := to_idate(date, "health record date")]
aligned <- merge(
  health,
  included_subjects[
    ,
    .(
      subject_id,
      personalId,
      birth_date,
      gender,
      age,
      heartattack_date,
      heartattack_type,
      has_received_physiotherapy
    )
  ],
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
    "birth_date",
    "gender",
    "age",
    "heartattack_date",
    "heartattack_type",
    "has_received_physiotherapy",
    "record_date",
    "relative_day",
    setdiff(names(aligned), c(
      "subject_id",
      "personalId",
      "birth_date",
      "gender",
      "age",
      "heartattack_date",
      "heartattack_type",
      "has_received_physiotherapy",
      "record_date",
      "relative_day"
    ))
  )
)
setorder_existing(
  aligned,
  c("subject_id", "relative_day", "record_date", "dateFrom", "dataType")
)

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
  included_subjects[
    ,
    .(
      subject_id,
      personalId,
      birth_date,
      gender,
      age,
      heartattack_date,
      heartattack_type,
      has_received_physiotherapy
    )
  ],
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
