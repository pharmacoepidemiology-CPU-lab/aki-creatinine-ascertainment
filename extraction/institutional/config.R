# 三院血清肌酐提取：当前确认版本的参数。
# 通常只需修改 input_root 和 output_root。源数据目录始终只读。
# output_root 使用新目录；现有六份交付文件位于 existing_output_root。
cfg <- list(
  input_root = "G:/麻醉数据集/标化数据整合",
  existing_output_root = "G:/麻醉数据集/肌酐记录_1105",
  output_root = "G:/麻醉数据集/肌酐记录_R版重新提取_20261108",
  audit_root = "D:/ResearchOutput/AKI_ICU_Unknown_20261108",
  cohorts = c("NJF", "AHMU", "ZD"),
  lookback_days = 365,
  followup_days = 90,
  umol_per_mgdl = 88.42,
  min_umol_exclusive = 5,
  max_umol_exclusive = 4000,
  serum_only = TRUE,
  exclude_unknown_units = TRUE,
  nonserum_name_pattern = "尿|urine|比值|ratio|清除|clearance|gfr|/|／",
  nonserum_specimen_pattern = "尿|urine|引流液|腹透液|腹水|胸水|穿刺液|积液|^体液$|脑脊液|羊水|胆汁|关节液|透析液|唾液|粪|drainage|dialysate|ascites|pleural|cerebrospinal|amniotic|bile|synovial|saliva|stool",
  exclude_incomplete_operation_keys = TRUE,
  invalid_historical_dates_are_missing = TRUE,
  minimum_valid_year = 1900,
  lab_time_priority = c("SPCM_RECEIVED_DATE_TIME", "RESULT_DATE_TIME", "RESULTS_RPT_DATE_TIME"),
  operation_time_priority = c("START_DATE_TIME", "ANES_START_TIME", "IN_DATE_TIME"),
  deduplicate_measurements_in_export = FALSE
)

# 仅核验目前这六份文件时使用，不限制未来新数据重提取的样本量。
expected_current_counts <- list(
  NJF = c(covariates_rows=210179, covariates_patients=199537,
          series_rows=626773, series_patients=159807, series_episodes=168244),
  AHMU = c(covariates_rows=337357, covariates_patients=316395,
           series_rows=565106, series_patients=225062, series_episodes=241795),
  ZD = c(covariates_rows=324573, covariates_patients=312550,
         series_rows=712538, series_patients=268945, series_episodes=280252)
)
