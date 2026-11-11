invisible(Sys.setlocale("LC_CTYPE", ".UTF-8"))
args <- commandArgs(trailingOnly=TRUE)
this_file <- sub("^--file=","",commandArgs(FALSE)[grepl("^--file=",commandArgs(FALSE))][1])
script_dir <- dirname(normalizePath(this_file,winslash="/",mustWork=TRUE))
source(file.path(script_dir,"helpers.R"),encoding="UTF-8")
source(file.path(script_dir,"config.R"),encoding="UTF-8")
dir.create(cfg$audit_root,showWarnings=FALSE,recursive=TRUE)
phase <- "arguments";current_hospital <- NA_character_

run <- function() {
  stopifnot(length(args)==1L,args[1] %chin% c("--current","--output"))
  current <- args[1]=="--current"
  root <- if(current)cfg$existing_output_root else cfg$output_root
  output_paths <- unlist(lapply(cfg$cohorts,function(h)file.path(root,paste0(h,c("_episode_covariates.csv","_creatinine_series.csv")))))
  source_paths <- unlist(lapply(cfg$cohorts,function(h)file.path(cfg$input_root,h,c("01.csv","03.csv","13.csv"))))
  inputs <- metadata(c(source_paths,output_paths))
  summaries <- list();manifest <- list()
  numeric_fields <- c("age","bmi","asa","emergency","hosp_los_days","icu_los_days","icu_admitted","discharge_t_days","death_t_days","died_inhosp")
  for(h in cfg$cohorts) {
    current_hospital <<- h;phase <<- "rebuild_covariates"
    message("CHECKING ",h)
    con <- new_connection();expected <- build_episodes(cfg,h,con)$data
    dbDisconnect(con,shutdown=TRUE);rm(con)
    paths <- file.path(root,paste0(h,c("_episode_covariates.csv","_creatinine_series.csv")))
    cv <- safe_fread(paths[1],encoding="UTF-8",colClasses="character",na.strings=NULL,showProgress=FALSE)
    stopifnot(identical(names(cv),EPISODE_FIELDS),nrow(cv)==nrow(expected),uniqueN(cv$episode_id)==nrow(cv))
    matched <- match(cv$episode_id,expected$episode_id);stopifnot(!anyNA(matched))
    expected <- expected[matched]
    differences <- setNames(integer(length(EPISODE_FIELDS)),EPISODE_FIELDS)
    for(k in EPISODE_FIELDS) {
      if(k %chin% numeric_fields) {
        a <- number(cv[[k]]);b <- expected[[k]]
        equal <- (is.na(a)&is.na(b))|(!is.na(a)&!is.na(b)&abs(a-b)<=1e-9+1e-12*pmax(abs(a),abs(b)))
      } else {
        a <- cv[[k]];b <- as.character(expected[[k]]);a[is.na(a)]<-"";b[is.na(b)]<-""
        equal <- a==b
      }
      equal[is.na(equal)]<-FALSE;differences[k] <- sum(!equal)
    }
    stopifnot(all(differences==0L))
    phase <<- "check_creatinine_output"
    sv <- safe_fread(paths[2],encoding="UTF-8",colClasses="character",na.strings=NULL,showProgress=FALSE)
    stopifnot(identical(names(sv),SERIES_FIELDS),all(sv$source==h),all(sv$unit=="mg/dL"))
    episode_positions <- match(sv$episode_id,cv$episode_id)
    stopifnot(!anyNA(episode_positions),identical(sv$patient_id,cv$patient_id[episode_positions]))
    td <- number(sv$t_days);values <- number(sv$value)
    stopifnot(!anyNA(td),!anyNA(values),all(values>0),all(td>=-cfg$lookback_days & td<=cfg$followup_days))
    # Exported timestamps have one normalized format; never guess mixed formats here.
    lab_time <- as.POSIXct(sv$chart_time,format="%Y-%m-%d %H:%M:%OS",tz="UTC")
    t0 <- as.POSIXct(cv$t0[episode_positions],format="%Y-%m-%d %H:%M:%OS",tz="UTC")
    stopifnot(!anyNA(lab_time),!anyNA(t0),all(abs(as.numeric(difftime(lab_time,t0,units="days"))-td)<=0.000005+1e-10))
    counts <- c(covariates_rows=nrow(cv),covariates_patients=uniqueN(cv$patient_id),
                series_rows=nrow(sv),series_patients=uniqueN(sv$patient_id),series_episodes=uniqueN(sv$episode_id))
    if(current)stopifnot(identical(unname(as.numeric(counts)),unname(as.numeric(expected_current_counts[[h]]))))
    sex_counts <- as.list(table(ifelse(nzchar(cv$sex),cv$sex,"Missing")))
    summaries[[h]] <- list(counts=as.list(counts),covariate_field_differences=as.list(differences),
      sex=sex_counts,creatinine_episode_match_rate=1,output_fields_match=TRUE)
    manifest[[length(manifest)+1L]] <- list(hospital=h,file=basename(paths[1]),path=paths[1],rows=nrow(cv),patients=uniqueN(cv$patient_id),columns=ncol(cv))
    manifest[[length(manifest)+1L]] <- list(hospital=h,file=basename(paths[2]),path=paths[2],rows=nrow(sv),patients=uniqueN(sv$patient_id),columns=ncol(sv))
    cat(toJSON(list(hospital=h,status="PASS",counts=as.list(counts),covariate_fields_matching=19L),auto_unbox=TRUE),"\n")
    rm(expected,cv,sv,lab_time,t0,episode_positions,matched);invisible(gc(FALSE))
  }
  after <- metadata(c(source_paths,output_paths));stopifnot(identical(inputs,after))
  result <- list(status="PASS",mode=args[1],checked_at=format(Sys.time(),"%Y-%m-%d %H:%M:%S %z"),
    data_files_unchanged=TRUE,manifest=manifest,cohorts=summaries,input_metadata=inputs,
    scope="All covariate fields rebuilt from source; all exported creatinine rows checked for schema, linkage and relative-time consistency. Laboratory source extraction not rerun.")
  name <- if(current)"current_six_files_check.json" else "new_exports_check.json"
  write_json(result,file.path(cfg$audit_root,name),pretty=TRUE,auto_unbox=TRUE,na="null",digits=16)
  cat(toJSON(list(status="PASS",files_checked=length(manifest),data_files_unchanged=TRUE),auto_unbox=TRUE),"\n")
}
tryCatch(run(),error=function(e){
  failure <- list(status="FAIL",hospital=current_hospital,phase=phase,
                  error_class=class(e),message="Record details suppressed to protect patient data")
  write_json(failure,file.path(cfg$audit_root,"check_error.json"),pretty=TRUE,auto_unbox=TRUE,na="null")
  cat(toJSON(failure,auto_unbox=TRUE),"\n");quit(status=1L)
})
