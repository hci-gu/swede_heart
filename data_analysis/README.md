# Data Analysis

R scripts for building analysis-ready datasets inside the secure vault.

## 1. Build Aligned Dataset

Script:

```bash
Rscript data_analysis/scripts/01_build_aligned_dataset.R \
  --health-records /path/to/health_records.csv \
  --keys /path/to/pnrkey_DAT-1261.xlsx \
  --clinical /path/to/health_information.csv \
  --clinical-heartattack-date-col heartattack_date \
  --output-dir /path/to/derived
```

Outputs:

```text
subject_index.csv
health_records_aligned.csv
daily_features_aligned.csv
```

`subject_index.csv` has one row per person and defines the analysis cohort.

`health_records_aligned.csv` keeps one row per health record and adds:

```text
subject_id
heartattack_date
record_date
relative_day
```

`daily_features_aligned.csv` has one row per person per relative day, with daily
summary features such as step sums and walking speed summaries.

## Assumptions

- `health_records.csv` comes from `scripts/transform_all_health_records.py`.
- The key file may be `.xlsx`, `.xls`, or `.csv`.
- For Excel key files, column A is treated as the analysis key/ID and column B
  as `personalId`.
- Excel key-file personal IDs may be written as `YYYYMMDDXXXX`; the script
  normalizes them to `YYYYMMDD-XXXX` before joining.
- `relative_day = record_date - heartattack_date`.
- `relative_day < 0` means before the heart attack.
- `relative_day = 0` means the heart attack date.
- `relative_day > 0` means after the heart attack.
- If a person has multiple heart attack dates in the clinical file, the script
  currently uses the earliest non-missing date.

## Useful Options

```bash
--health-personal-id-col personalId
--key-personal-id-col personalId
--key-id-col key
--clinical-personal-id-col personalId
--clinical-heartattack-date-col heartattack_date
--window-before 365
--window-after 365
```

Use `--window-before` and `--window-after` to restrict the aligned records to a
specific analysis window around the heart attack date.

## Dependency

The scripts use:

- `data.table` for fast CSV processing.
- `readxl` for `.xlsx`/`.xls` key files.
