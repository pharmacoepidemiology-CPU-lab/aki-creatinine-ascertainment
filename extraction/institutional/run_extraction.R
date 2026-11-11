invisible(Sys.setlocale("LC_CTYPE", ".UTF-8"))
args <- commandArgs(trailingOnly=TRUE)
this_file <- sub("^--file=","",commandArgs(FALSE)[grepl("^--file=",commandArgs(FALSE))][1])
script_dir <- dirname(normalizePath(this_file,winslash="/",mustWork=TRUE))
source(file.path(script_dir,"helpers.R"),encoding="UTF-8")
source(file.path(script_dir,"config.R"),encoding="UTF-8")
dir.create(cfg$audit_root,showWarnings=FALSE,recursive=TRUE)
phase <- "arguments"; current_hospital <- NA_character_

run <- function() {
  stopifnot(length(args)>=1L,args[1] %chin% c("--validate-only","--export"))
  mode <- args[1]
  cohorts <- if(length(args)>1L)unique(args[-1]) else cfg$cohorts
  stopifnot(all(cohorts %chin% cfg$cohorts))
  source_paths <- unlist(lapply(cfg$cohorts,function(h)c(file.path(cfg$input_root,h,c("01.csv","03.csv","13.csv")),lab_files(cfg$input_root,h))))
  inputs <- metadata(source_paths)
  validation_path <- file.path(cfg$audit_root,"r_validation.json")
  if(mode=="--validate-only") {
    stopifnot(length(args)==1L)
    checks <- list()
    for(h in cfg$cohorts) {
      current_hospital <<- h;phase <<- "validate_episode_inputs"
      message("VALIDATING ",h)
      con <- new_connection();ep <- build_episodes(cfg,h,con)
      for(p in lab_files(cfg$input_root,h))
        stopifnot(all(c("PATIENT_ID","REPORT_ITEM_NAME","RESULT","UNITS","SPECIMEN",cfg$lab_time_priority) %in% header_of(p)))
      checks[[h]] <- ep$qa
      dbDisconnect(con,shutdown=TRUE);rm(con,ep);invisible(gc(FALSE))
    }
    after <- metadata(source_paths)
    stopifnot(identical(inputs,after))
    result <- list(status="PASS",config=cfg,inputs=inputs,cohorts=checks,
                   validated_at=format(Sys.time(),"%Y-%m-%d %H:%M:%S %z"))
    write_json(result,validation_path,pretty=TRUE,auto_unbox=TRUE,na="null",digits=16)
    cat(toJSON(list(status="PASS",mode=mode,cohorts=checks),auto_unbox=TRUE),"\n")
    return(invisible(NULL))
  }
  phase <<- "validated_input_gate"
  checked <- fromJSON(validation_path)
  stopifnot(checked$status=="PASS",identical(checked$config,fromJSON(toJSON(cfg,auto_unbox=TRUE,digits=16))),
            identical(as.character(inputs$path),as.character(checked$inputs$path)),
            all(inputs$bytes==checked$inputs$bytes),all(abs(inputs$mtime-checked$inputs$mtime)<.01))
  paths_all <- unlist(lapply(cohorts,function(h)file.path(cfg$output_root,paste0(h,c("_episode_covariates.csv","_creatinine_series.csv")))))
  # Re-extraction writes a new result directory. It never replaces prior exports.
  stopifnot(!any(file.exists(paths_all)),!any(file.exists(paste0(paths_all,".partial"))))
  dir.create(cfg$output_root,recursive=TRUE,showWarnings=FALSE)
  receipts <- list()
  for(h in cohorts) {
    current_hospital <<- h;phase <<- "build_episodes"
    message("EXPORTING ",h)
    con <- new_connection();ep <- build_episodes(cfg,h,con)
    phase <<- "scan_creatinine";labqa <- collect_candidates(cfg,h,con)
    phase <<- "link_creatinine"
    sql <- paste0("SELECT e.source,e.episode_id,e.patient_id,",time_string("c.lab_time"),
      " AS chart_time,date_diff('microsecond',e.time_zero,c.lab_time)/86400000000.0 AS t_days,c.value_umol/",
      cfg$umol_per_mgdl," AS value,'mg/dL' AS unit FROM creatinine c INNER JOIN episodes e ON c.patient_id=e.patient_id AND c.lab_time>=e.time_zero-INTERVAL ",
      cfg$lookback_days," DAY AND c.lab_time<=e.time_zero+INTERVAL ",cfg$followup_days," DAY WHERE c.lab_time IS NOT NULL")
    series <- as.data.table(dbGetQuery(con,sql))
    series[,`:=`(t_days=round(t_days,5),value=round(value,4))]
    setorder(series,episode_id,t_days)
    stopifnot(identical(names(series),SERIES_FIELDS),all(series$episode_id %chin% ep$data$episode_id),
              all(series$unit=="mg/dL"),all(series$t_days>=-cfg$lookback_days & series$t_days<=cfg$followup_days))
    paths <- file.path(cfg$output_root,paste0(h,c("_episode_covariates.csv","_creatinine_series.csv")))
    partial <- paste0(paths,".partial")
    phase <<- "write_and_read_back_outputs"
    fwrite(ep$data,partial[1],bom=TRUE,quote=TRUE,na="",dateTimeAs="write.csv",nThread=2L)
    fwrite(series,partial[2],bom=TRUE,quote=TRUE,na="",dateTimeAs="write.csv",nThread=2L)
    cv <- safe_fread(partial[1],encoding="UTF-8",colClasses="character",na.strings=NULL,showProgress=FALSE)
    sv <- safe_fread(partial[2],encoding="UTF-8",colClasses="character",na.strings=NULL,showProgress=FALSE)
    stopifnot(nrow(cv)==nrow(ep$data),nrow(sv)==nrow(series),
      identical(names(cv),EPISODE_FIELDS),identical(names(sv),SERIES_FIELDS),
      identical(cv$episode_id,ep$data$episode_id),identical(cv$patient_id,ep$data$patient_id),
      identical(cv$visit_id,ep$data$visit_id),identical(cv$oper_id,ep$data$oper_id),
      identical(sv$episode_id,series$episode_id),identical(sv$patient_id,series$patient_id),
      all(abs(number(sv$t_days)-series$t_days)<1e-10),all(abs(number(sv$value)-series$value)<1e-10))
    stopifnot(!any(file.exists(paths)),all(file.rename(partial,paths)))
    labqa$series_rows <- nrow(series)
    labqa$episodes_with_creatinine <- uniqueN(series$episode_id)
    labqa$patients_with_creatinine <- uniqueN(series$patient_id)
    labqa$median_mg_dl <- median(series$value)
    labqa$exact_duplicate_measurements_retained_for_downstream_pipeline <- nrow(series)-uniqueN(series,by=c("episode_id","t_days","value"))
    receipt <- list(status="PASS",hospital=h,episodes=ep$qa,creatinine=labqa,
      output_paths=paths,output_bytes=as.numeric(file.info(paths)$size),episode_fields=EPISODE_FIELDS,series_fields=SERIES_FIELDS)
    write_json(receipt,file.path(cfg$audit_root,paste0(h,"_r_export_check.json")),pretty=TRUE,auto_unbox=TRUE,na="null",digits=16)
    receipts[[h]] <- list(episode_rows=nrow(ep$data),series_rows=nrow(series),
      patients=ep$qa$patients,episodes_with_creatinine=labqa$episodes_with_creatinine)
    message(h," completed: episodes=",nrow(ep$data),"; series=",nrow(series))
    dbDisconnect(con,shutdown=TRUE);rm(con,ep,series,cv,sv);invisible(gc(FALSE))
  }
  phase <<- "final_input_check"
  after <- metadata(source_paths)
  stopifnot(identical(inputs,after))
  write_json(list(status="PASS",counts=receipts,inputs_unchanged=TRUE,config=cfg,inputs=inputs),
    file.path(cfg$audit_root,"r_export_completed.json"),pretty=TRUE,auto_unbox=TRUE,na="null",digits=16)
  cat(toJSON(list(status="PASS",counts=receipts),auto_unbox=TRUE),"\n")
}

tryCatch(run(),error=function(e){
  failure <- list(status="FAIL",hospital=current_hospital,phase=phase,
                  error_class=class(e),message="Record details suppressed to protect patient data")
  write_json(failure,file.path(cfg$audit_root,"r_error.json"),pretty=TRUE,auto_unbox=TRUE,na="null")
  cat(toJSON(failure,auto_unbox=TRUE),"\n");quit(status=1L)
})
