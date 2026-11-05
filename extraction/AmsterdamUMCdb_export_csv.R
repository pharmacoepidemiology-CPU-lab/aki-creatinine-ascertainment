rm(list = ls())

# AmsterdamUMCdb: complete creatinine series for every ICU/MC episode
# CSV version: reads the AmsterdamUMCdb release files directly with DuckDB.
# No PostgreSQL / psql / SQL client is needed.
#
# Output 1: AmsterdamUMCdb_creatinine_series.csv   (one row per creatinine result)
# Output 2: AmsterdamUMCdb_episode_covariates.csv  (one row per admission, including
#           admissions with no creatinine measurement)
#
# Same rules as the PostgreSQL version (AmsterdamUMCdb_export.R):
# - times are AmsterdamUMCdb millisecond offsets; t0 = admissions.admittedat
# - creatinine itemids 6836 and 9941 (micromol/L), converted to mg/dL (/ 88.4)
# - every creatinine result of the same patient from 365 days before to 90 days
#   after t0, including results attached to another admission
# - values kept if > 0 and < 50 mg/dL (4420 micromol/L)
# - age = midpoint of agegroup (80+ -> 85); ASA and hospital LOS are NA
#
# Reference run (Bongani, verified): 23,106 episodes, 20,109 patients,
# 291,175 creatinine rows, 22,991 episodes with >= 1 result, median 0.950 mg/dL.
#
# Requirements: install.packages(c("data.table", "duckdb", "DBI"))
# Run time: numericitems.csv is very large (hundreds of millions of rows);
# the single scan of it can take 10-40 minutes. This is normal.

suppressPackageStartupMessages({
  library(data.table)
  library(DBI)
  library(duckdb)
})

# ================================================================ CHANGE THESE TWO
# 1. Folder that contains admissions.csv and numericitems.csv
#    (the unzipped AmsterdamUMCdb release; .csv.gz files also work)
AMDS_DIR <- "path/to/AmsterdamUMCdb"
# 2. Folder where the two output files will be written
OUT_DIR  <- "path/to/amsterdam_output"
# ================================================================

LOOKBACK_DAYS <- 365L
FOLLOWUP_DAYS <- 90L
MS_PER_DAY <- 1000 * 60 * 60 * 24
CREAT_ITEMIDS <- c(6836L, 9941L)
UMOL_L_PER_MG_DL <- 88.4

find_file <- function(stem) {
  cand <- file.path(AMDS_DIR, paste0(stem, c(".csv", ".csv.gz")))
  hit <- cand[file.exists(cand)]
  if (!length(hit)) stop("Cannot find ", stem, ".csv in ", normalizePath(AMDS_DIR, mustWork = FALSE),
                         "\nCheck AMDS_DIR: it must be the folder that holds admissions.csv and numericitems.csv.")
  normalizePath(hit[1], winslash = "/")
}
adm_file <- find_file("admissions")
num_file <- find_file("numericitems")

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
series_path   <- normalizePath(file.path(OUT_DIR, "AmsterdamUMCdb_creatinine_series.csv"), winslash = "/", mustWork = FALSE)
episode_path  <- normalizePath(file.path(OUT_DIR, "AmsterdamUMCdb_episode_covariates.csv"), winslash = "/", mustWork = FALSE)
log_path      <- file.path(OUT_DIR, "extraction_log.txt")
manifest_path <- file.path(OUT_DIR, "reproducibility_manifest.txt")
q <- function(x) gsub("'", "''", x)

con <- dbConnect(duckdb::duckdb(), dbdir = ":memory:")
dbExecute(con, sprintf("SET temp_directory = '%s'", q(normalizePath(OUT_DIR, winslash = "/"))))

cat("AmsterdamUMCdb creatinine export (CSV/DuckDB version)\n", file = log_path)
cat(sprintf("Started: %s\n", format(Sys.time(), tz = "Asia/Shanghai")), file = log_path, append = TRUE)
cat(sprintf("admissions file: %s\nnumericitems file: %s\n", adm_file, num_file), file = log_path, append = TRUE)
cat(sprintf("Window: -%d to +%d days around each ICU/MC admission t0\n", LOOKBACK_DAYS, FOLLOWUP_DAYS),
    file = log_path, append = TRUE)

# AmsterdamUMCdb CSV files are Latin-1 encoded (e.g. the "µ" in µmol/l).
# The encoding option needs duckdb 1.1 or newer.
read_csv_sql <- function(path, types = NULL) {
  ty <- if (is.null(types)) "" else
    paste0(", types = {", paste(sprintf("'%s': '%s'", names(types), types), collapse = ", "), "}")
  sprintf("read_csv('%s', header = true, encoding = 'latin-1'%s)", q(path), ty)
}
tryCatch({
  dbExecute(con, sprintf("CREATE OR REPLACE VIEW admissions AS SELECT * FROM %s",
                         read_csv_sql(adm_file, c(admissionid = "BIGINT", patientid = "BIGINT",
                                                  admittedat = "BIGINT", dischargedat = "BIGINT",
                                                  dateofdeath = "BIGINT"))))
  n_adm <- dbGetQuery(con, "SELECT count(*) AS n FROM admissions")$n
}, error = function(e) stop(
  "Could not read admissions.csv: ", conditionMessage(e),
  "\nIf the message mentions 'encoding', update duckdb first: install.packages(\"duckdb\"), then restart R."))
cat(sprintf("admissions.csv rows: %s\n", format(n_adm, big.mark = ",")))

# ---------------------------------------------------------------- 1. creatinine rows (one scan of numericitems)
cat("Reading creatinine from numericitems (this is the slow step) ...\n")
creat_sql <- function(src) sprintf("
  CREATE OR REPLACE TABLE creat AS
  SELECT * FROM (
    SELECT TRY_CAST(admissionid AS BIGINT) AS admissionid,
           TRY_CAST(itemid AS BIGINT)      AS itemid,
           TRY_CAST(value AS DOUBLE)       AS value,
           CAST(unit AS VARCHAR)           AS unit,
           TRY_CAST(measuredat AS BIGINT)  AS measuredat
    FROM %s
  ) n
  WHERE itemid IN (%s)
    AND value IS NOT NULL
    AND measuredat IS NOT NULL
    AND value > 0
    AND value < (50 * %s)",
  src, paste(CREAT_ITEMIDS, collapse = ", "), UMOL_L_PER_MG_DL)
num_src <- read_csv_sql(num_file, c(admissionid = "BIGINT", itemid = "BIGINT", value = "DOUBLE",
                                    measuredat = "BIGINT", unit = "VARCHAR"))
# If DuckDB guesses the type of some other column wrongly (e.g. 'comment'),
# read every column as text instead and convert only the five we need.
tryCatch(dbExecute(con, creat_sql(num_src)), error = function(e) {
  cat("Typed read failed (", conditionMessage(e), "); retrying with all columns as text ...\n")
  s <- read_csv_sql(num_file)
  dbExecute(con, creat_sql(paste0(substr(s, 1, nchar(s) - 1), ", all_varchar = true)")))
})
cat(sprintf("Creatinine results found: %s\n",
            format(dbGetQuery(con, "SELECT count(*) AS n FROM creat")$n, big.mark = ",")))

# ---------------------------------------------------------------- 2. episodes
cat("Exporting episode_covariates.csv ...\n")
dbExecute(con, sprintf("
COPY (
  SELECT
    'AmsterdamUMCdb' AS source,
    CAST(a.admissionid AS VARCHAR) AS episode_id,
    CAST(a.patientid AS VARCHAR) AS patient_id,
    a.admittedat AS t0,
    CAST(CASE CAST(a.agegroup AS VARCHAR)
      WHEN '18-39' THEN 28.5
      WHEN '40-49' THEN 44.5
      WHEN '50-59' THEN 54.5
      WHEN '60-69' THEN 64.5
      WHEN '70-79' THEN 74.5
      WHEN '80+'   THEN 85.0
      ELSE NULL END AS DOUBLE) AS age,
    CASE
      WHEN lower(CAST(a.gender AS VARCHAR)) IN ('man', 'male') THEN 'M'
      WHEN lower(CAST(a.gender AS VARCHAR)) IN ('vrouw', 'female') THEN 'F'
      ELSE CAST(a.gender AS VARCHAR) END AS sex,
    CAST(NULL AS DOUBLE) AS asa,
    CAST(TRY_CAST(a.urgency AS BOOLEAN) AS INTEGER) AS emergency,
    CAST(NULL AS DOUBLE) AS hosp_los_days,
    CAST(a.dischargedat - a.admittedat AS DOUBLE) / %1$s AS icu_los_days,
    a.dischargedat AS discharge_time,
    a.dateofdeath AS death_time,
    CAST(a.dischargedat - a.admittedat AS DOUBLE) / %1$s AS discharge_t_days,
    CASE WHEN a.dateofdeath IS NULL THEN NULL
         ELSE CAST(a.dateofdeath - a.admittedat AS DOUBLE) / %1$s END AS death_t_days,
    CAST(a.agegroup AS VARCHAR) AS age_group,
    CAST(a.location AS VARCHAR) AS icu_location,
    CAST(a.specialty AS VARCHAR) AS specialty,
    CAST(a.admissioncount AS INTEGER) AS admission_count,
    CAST(a.admissionyeargroup AS VARCHAR) AS admission_year_group,
    CASE WHEN a.dateofdeath IS NOT NULL
          AND a.dateofdeath >= a.admittedat
          AND a.dateofdeath <= a.dischargedat THEN 1 ELSE 0 END AS died_during_episode,
    'age is age-group midpoint; ASA and hospital LOS unavailable' AS source_specific_note
  FROM admissions a
  ORDER BY a.admissionid
) TO '%2$s' (HEADER, DELIMITER ',')",
  format(MS_PER_DAY, scientific = FALSE), q(episode_path)))

# ---------------------------------------------------------------- 3. series
# Join by patient (not admission) so results from other admissions and from
# before admission are found, exactly as in the PostgreSQL version.
cat("Exporting creatinine_series.csv ...\n")
dbExecute(con, sprintf("
COPY (
  WITH cr AS (
    SELECT src.patientid, n.admissionid AS source_admissionid, n.itemid,
           n.measuredat, n.value AS creatinine_umol_l, n.unit AS original_unit
    FROM creat n
    INNER JOIN admissions src ON src.admissionid = n.admissionid
  )
  SELECT
    'AmsterdamUMCdb' AS source,
    CAST(ep.admissionid AS VARCHAR) AS episode_id,
    CAST(ep.patientid AS VARCHAR) AS patient_id,
    cr.measuredat AS "timestamp",
    round(CAST(cr.measuredat - ep.admittedat AS DOUBLE) / %1$s, 5) AS t_days,
    cr.creatinine_umol_l / %2$s AS value,
    'mg/dL' AS unit,
    CAST(cr.source_admissionid AS VARCHAR) AS source_admission_id,
    cr.itemid AS source_itemid,
    cr.creatinine_umol_l AS original_value,
    cr.original_unit AS original_unit
  FROM admissions ep
  INNER JOIN cr
    ON cr.patientid = ep.patientid
   AND cr.measuredat >= ep.admittedat - (%3$d * CAST(%1$s AS BIGINT))
   AND cr.measuredat <= ep.admittedat + (%4$d * CAST(%1$s AS BIGINT))
  ORDER BY ep.admissionid, cr.measuredat, cr.source_admissionid, cr.itemid
) TO '%5$s' (HEADER, DELIMITER ',')",
  format(MS_PER_DAY, scientific = FALSE), UMOL_L_PER_MG_DL, LOOKBACK_DAYS, FOLLOWUP_DAYS, q(series_path)))

# ---------------------------------------------------------------- 4. checks
cat("Running sanity checks ...\n")
episodes <- fread(episode_path, colClasses = list(character = c("episode_id", "patient_id")))
series <- fread(series_path, colClasses = list(character = c("episode_id", "patient_id", "source_admission_id")))

required_episode <- c("episode_id", "patient_id", "t0", "age", "sex", "asa", "emergency",
                      "hosp_los_days", "icu_los_days", "discharge_time", "death_time",
                      "discharge_t_days", "death_t_days")
required_series <- c("episode_id", "patient_id", "timestamp", "t_days", "value", "unit")
stopifnot(all(required_episode %in% names(episodes)))
stopifnot(all(required_series %in% names(series)))
stopifnot(nrow(episodes) == uniqueN(episodes$episode_id))
stopifnot(all(series$t_days >= -LOOKBACK_DAYS & series$t_days <= FOLLOWUP_DAYS))
stopifnot(all(series$unit == "mg/dL"))

n_with <- uniqueN(series$episode_id)
n_per <- series[, .N, by = episode_id]
qc <- c(
  sprintf("Completed: %s", format(Sys.time(), tz = "Asia/Shanghai")),
  sprintf("Episodes: %s   (reference 23,106)", format(nrow(episodes), big.mark = ",")),
  sprintf("Unique patients: %s   (reference 20,109)", format(uniqueN(episodes$patient_id), big.mark = ",")),
  sprintf("Creatinine rows: %s   (reference 291,175)", format(nrow(series), big.mark = ",")),
  sprintf("Episodes with >=1 result: %s (%.2f%%)   (reference 22,991)", format(n_with, big.mark = ","),
          100 * n_with / nrow(episodes)),
  sprintf("Median creatinine: %.3f mg/dL   (reference 0.950)", median(series$value, na.rm = TRUE)),
  sprintf("Results/episode among measured: median %d, IQR %d-%d, max %d",
          as.integer(median(n_per$N)), as.integer(quantile(n_per$N, .25)),
          as.integer(quantile(n_per$N, .75)), max(n_per$N))
)
dbDisconnect(con, shutdown = TRUE)
write(qc, file = log_path, append = TRUE)
writeLines(c(
  "AmsterdamUMCdb creatinine export reproducibility manifest (CSV/DuckDB version)",
  paste0("generated_at=", format(Sys.time(), tz = "Asia/Shanghai")),
  paste0("r_version=", R.version.string),
  paste0("data_table_version=", as.character(packageVersion("data.table"))),
  paste0("duckdb_version=", as.character(packageVersion("duckdb"))),
  paste0("admissions_file=", adm_file),
  paste0("numericitems_file=", num_file),
  "episode_definition=one ICU/MC admission; t0=admissions.admittedat",
  paste0("lookback_days=", LOOKBACK_DAYS), paste0("followup_days=", FOLLOWUP_DAYS),
  paste0("creatinine_itemids=", paste(CREAT_ITEMIDS, collapse = ",")),
  paste0("conversion=original_micromol_per_litre/", UMOL_L_PER_MG_DL),
  paste0("episode_rows=", nrow(episodes)), paste0("unique_patients=", uniqueN(episodes$patient_id)),
  paste0("series_rows=", nrow(series)),
  paste0("episode_covariates_md5=", unname(tools::md5sum(episode_path))),
  paste0("creatinine_series_md5=", unname(tools::md5sum(series_path)))
), manifest_path, useBytes = TRUE)
cat(paste(qc, collapse = "\n"), "\n")
cat("\nCreated:\n", episode_path, "\n", series_path, "\n")
