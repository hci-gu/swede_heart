# Data Analysis

R scripts for building analysis-ready datasets inside the secure vault.

## 0. Build Full Export On The Analysis Server

Preferred handoff workflow:

1. Upload or sync the raw download directory to the secure analysis server.
2. Run the full export in R on that server, where the key and clinical files live.

```bash
Rscript data_analysis/scripts/00_build_full_export.R \
  --raw-data-dir /path/to/raw-download \
  --output-dir /path/to/full_export \
  --keys /path/to/pnrkey_DAT-1261.xlsx \
  --clinical /path/to/health_information.xlsx \
  --window-before 365 \
  --window-after 365 \
  --skip-raw-health-records true \
  --skip-daily-health-records-gz true \
  --workers 12
```

Main outputs:

```text
export_logs/daily_health_records_transform/daily_health_records.csv
keys_sensitive_separate/personal_id_map.csv
derived/clinical_alignment/subject_index.csv
derived/clinical_alignment/health_records_aligned.csv
derived/clinical_alignment/daily_features_aligned.csv
manifest.json
checksums.md5
```

Use `--skip-raw-health-records true --skip-daily-health-records-gz true` when
the goal is only the aligned analysis outputs. This omits
`raw/health_records.csv.gz`, skips raw-only JSON serialization, and avoids
writing a compressed duplicate of the daily alignment input. Leave those false
if you also need one tidy row per raw health record and a compressed daily
handoff file.

`--workers` parallelizes the per-user raw JSON to daily-record transform. It is
available for aligned-output runs where both `--skip-raw-health-records true`
and `--skip-daily-health-records-gz true` are set.

Run a parallel-path smoke test first with `--test-run true`. This processes
only the first worker batch, then still writes the joined daily CSV, manifest,
checksums, and clinical alignment outputs:

```bash
Rscript data_analysis/scripts/00_build_full_export.R \
  --raw-data-dir /path/to/raw-download \
  --output-dir /path/to/aligned_export_test \
  --keys /path/to/pnrkey_DAT-1261.xlsx \
  --clinical /path/to/health_information.xlsx \
  --window-before 365 \
  --window-after 365 \
  --skip-raw-health-records true \
  --skip-daily-health-records-gz true \
  --workers 12 \
  --test-run true
```

Clinical alignment also extracts `has_received_physiotherapy` from sheet
`Physio`. By default, columns `E`, `F`, and `G` are checked; `Ja` in any of
those columns means `TRUE`, `Nej` means `FALSE`, and missing/no matching value
stays missing. The Physio sheet is joined with the same key as
`--clinical-key-col` unless `--clinical-physio-key-col` is provided.

Clinical alignment derives demographics from `personalId`:

- `birth_date` is parsed from the first eight digits, `YYYYMMDD`.
- `gender` uses the Swedish personal identity number convention where the
  third digit after the hyphen is odd for `male` and even for `female`.
- `age` is age in completed years at `heartattack_date`.

Dependencies:

- `data.table`
- `jsonlite`
- `readxl` if key or clinical files are Excel. If `readxl` is unavailable,
  provide those files as CSV instead.

## 1. Build Aligned Dataset

Script:

```bash
Rscript data_analysis/scripts/01_build_aligned_dataset.R \
  --health-records /path/to/health_records.csv \
  --keys /path/to/pnrkey_DAT-1261.xlsx \
  --clinical /path/to/health_information.csv \
  --output-dir /path/to/derived
```

Outputs:

```text
subject_index.csv
health_records_aligned.csv
daily_features_aligned.csv
```

## 2. Visualize Average Steps

Notebook:

```text
data_analysis/notebooks/average_steps_around_heartattack.Rmd
```

Open it in RStudio after running the aligned dataset script. By default it reads:

```text
../derived/daily_features_aligned.csv
```

The first plot shows average daily steps from 365 days before to 365 days after
heart attack date. The second plot shows how many subjects contribute step data
for each relative day.

The main plot can be changed in the notebook YAML:

```yaml
main_stat: "mean"        # "mean" or "median"
main_plot_type: "line"   # "line" or "boxplot"
```

`subject_index.csv` has one row per person and defines the analysis cohort.
It includes derived `birth_date`, `gender`, `age`, and
`has_received_physiotherapy`.

`health_records_aligned.csv` keeps one row per health record and adds:

```text
subject_id
heartattack_date
heartattack_type
record_date
relative_day
```

`daily_features_aligned.csv` has one row per person per relative day, with daily
summary features such as step sums and walking speed summaries.

## Assumptions

- `health_records.csv` comes from the health-record transform output, for
  example `daily_health_records.csv`.
- The health record numeric value column is auto-detected. The script uses
  `numericValue` when present, otherwise `value`.
- The key file may be `.xlsx`, `.xls`, or `.csv`.
- For Excel key files, column A is treated as `pseudo_PNR` and column B
  as `personalId`.
- Excel key-file personal IDs may be written as `YYYYMMDDXXXX`; the script
  normalizes them to `YYYYMMDD-XXXX` before joining.
- The clinical file may be `.xlsx`, `.xls`, or `.csv`.
- For Excel clinical files, the default sheet is `RiksHia`.
- For Excel clinical files, the clinical key defaults to `pseudo_PNR`.
- `pseudo_PNR` is matched to column A from the key file, then the key file maps
  that to `personalId`.
- For Excel clinical files, heart attack date defaults to column `P`.
- For Excel clinical files, heart attack type defaults to column `GJ`.
- `heartattack_type` is carried into all derived outputs.
- `relative_day = record_date - heartattack_date`.
- `relative_day < 0` means before the heart attack.
- `relative_day = 0` means the heart attack date.
- `relative_day > 0` means after the heart attack.
- If a person has multiple heart attack dates in the clinical file, the script
  currently uses the earliest non-missing date.

## Useful Options

```bash
--health-personal-id-col personalId
--health-value-col auto
--key-personal-id-col personalId
--key-id-col key
--clinical-key-col pseudo_PNR
--clinical-sheet RiksHia
--clinical-heartattack-date-col P
--clinical-heartattack-type-col GJ
--clinical-physio-sheet Physio
--clinical-physio-key-col pseudo_PNR
--clinical-physio-value-cols E,F,G
--window-before 365
--window-after 365
```

For Excel inputs, `--clinical-key-col`, `--clinical-heartattack-date-col`, and
`--clinical-heartattack-type-col` can be either a header name or an Excel column
letter such as `A`, `P`, or `GJ`.

Use `--window-before` and `--window-after` to restrict the aligned records to a
specific analysis window around the heart attack date.

## Dependency

The scripts use:

- `data.table` for fast CSV processing.
- `readxl` for `.xlsx`/`.xls` key and clinical files.
- `ggplot2` for notebook visualizations.
- `scales` for chart axis formatting.
