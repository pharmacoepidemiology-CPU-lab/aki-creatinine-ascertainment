invisible(Sys.setlocale("LC_CTYPE", ".UTF-8"))
.libPaths(c("D:/ResearchData/ZD_RLIB_ASCII", .libPaths()))
suppressPackageStartupMessages({library(data.table); library(jsonlite); library(DBI); library(duckdb)})
KEY <- c("PATIENT_ID", "VISIT_ID", "OPER_ID")
EPISODE_FIELDS <- c("source", "episode_id", "patient_id", "visit_id", "oper_id", "t0", "age", "sex", "bmi", "asa", "emergency", "operation_scale", "department", "hosp_los_days", "icu_los_days", "icu_admitted", "discharge_t_days", "death_t_days", "died_inhosp")
SERIES_FIELDS <- c("source", "episode_id", "patient_id", "chart_time", "t_days", "value", "unit")
lit <- function(x) paste0("'", gsub("'", "''", x, fixed = TRUE), "'")
unq <- function(x) gsub("^'|'$", "", trimws(as.character(x)))
number <- function(x) suppressWarnings(as.numeric(trimws(x)))
header_of <- function(p) names(fread(p, nrows = 0, encoding = "Latin-1", showProgress = FALSE))
metadata <- function(paths) {
  info <- file.info(paths)
  stopifnot(all(!is.na(info$size)))
  data.frame(path = paths, bytes = as.numeric(info$size), mtime = as.numeric(info$mtime))
}
safe_fread <- function(...) withCallingHandlers(fread(...), warning = function(w) stop("CSV parser warning; row details suppressed", call. = FALSE))
decode_mixed <- function(x) {
  Encoding(x) <- "unknown"
  idx <- which(!is.na(x) & grepl("[^ -~\t\r\n]", x, perl = TRUE, useBytes = TRUE))
  if (!length(idx)) return(x)
  bytes <- x[idx]
  decoded <- iconv(bytes, from = "UTF-8", to = "UTF-8", sub = NA)
  bad <- is.na(decoded)
  decoded[bad] <- iconv(bytes[bad], from = "GB18030", to = "UTF-8", sub = NA)
  # Never replace malformed identifier or selected clinical text silently.
  if (anyNA(decoded)) stop("Selected field cannot be decoded as UTF-8 or GB18030", call. = FALSE)
  x[idx] <- decoded
  x
}
read_small <- function(path, fields, mixed = FALSE, field_encodings = character()) {
  stopifnot(all(fields %in% header_of(path)))
  d <- safe_fread(path, select = fields, colClasses = "character", encoding = if(mixed) "unknown" else "UTF-8",
                  na.strings = NULL, strip.white = FALSE, showProgress = FALSE)
  if (mixed) for (k in names(d)) {
    value <- d[[k]]
    if (k %in% names(field_encodings)) {
      Encoding(value) <- "unknown"
      value <- iconv(value, from = field_encodings[[k]], to = "UTF-8", sub = NA)
      if (anyNA(value)) stop("Selected field cannot be decoded using its declared encoding", call. = FALSE)
    } else value <- decode_mixed(value)
    set(d, j = k, value = value)
  }
  for (k in intersect(KEY, names(d))) set(d, j = k, value = unq(d[[k]]))
  d
}
clean_sex <- function(x) {
  s <- trimws(x); out <- rep(NA_character_, length(s))
  out[grepl("男", s)] <- "Male"; out[grepl("女", s)] <- "Female"
  out[s %chin% c("1", "M", "Male")] <- "Male"
  out[s %chin% c("2", "F", "Female")] <- "Female"
  out
}
clean_asa <- function(x) {
  s <- trimws(gsub("级", "", trimws(x))); out <- rep(NA_integer_, length(s))
  groups <- list(c("I","Ⅰ","ⅰ","1","１"), c("II","Ⅱ","ⅱ","2","２"), c("III","Ⅲ","ⅲ","3","３"), c("IV","Ⅳ","ⅳ","4","４"), c("V","Ⅴ","ⅴ","5","５"))
  for (i in seq_along(groups)) out[s %chin% groups[[i]]] <- i
  out
}
ts_expr <- function(column) {
  raw <- paste0("nullif(trim(",column,"),'')")
  dmy <- paste0("try_strptime(",raw,",['%d/%m/%Y %H:%M:%S','%d-%m-%Y %H:%M:%S','%d.%m.%Y %H:%M:%S','%d/%m/%Y %H:%M','%d-%m-%Y %H:%M','%d.%m.%Y %H:%M','%d/%m/%Y','%d-%m-%Y','%d.%m.%Y'])")
  parsed <- paste0("CASE WHEN regexp_matches(",raw,",'^[0-9]{1,2}[/.-][0-9]{1,2}[/.-][0-9]{4}') THEN ",dmy," ELSE try_cast(",raw," AS TIMESTAMP) END")
  paste0("CASE WHEN year(",parsed,")>=1900 THEN ",parsed," ELSE NULL END")
}
time_string <- function(expr) paste0("regexp_replace(strftime(",expr,",'%Y-%m-%d %H:%M:%S.%f'),'[.]?0+$','')")
new_connection <- function() {
  c <- dbConnect(duckdb(), dbdir = ":memory:")
  dbExecute(c,"SET memory_limit='4GB'"); dbExecute(c,"SET threads=2"); dbExecute(c,"SET max_temp_directory_size='0GB'")
  c
}
scan_sql <- function(p) {
  cols <- paste0(lit(header_of(p)), ":'VARCHAR'", collapse = ",")
  paste0("read_csv(",lit(p),",header=true,auto_detect=false,columns={",cols,"},encoding='utf-8',delim=',',quote='\"',escape='\"',nullstr='',parallel=false,strict_mode=false,ignore_errors=false)")
}
lab_files <- function(root,hospital) {
  if (hospital == "AHMU") file.path(root,hospital,"AHMU 09",c("09_1.csv","09_2.csv")) else file.path(root,hospital,"09.csv")
}

# Record-safe, bounded binary chunks; no clinical temporary files.
read_selected_chunks <- function(path, fields, FUN, chunk_bytes = 16L*1024L*1024L) {
  all_fields <- header_of(path); positions <- match(fields, all_fields); stopifnot(!anyNA(positions))
  con <- file(path,"rb"); on.exit(close(con),add=TRUE)
  carry <- raw(); first <- TRUE
  consume <- function(bytes) {
    d <- safe_fread(text=rawToChar(bytes),header=first,select=positions,colClasses="character",sep=",",quote="\"",
                    na.strings=NULL,strip.white=FALSE,encoding="unknown",fill=FALSE,blank.lines.skip=TRUE,showProgress=FALSE,nThread=1L)
    first <<- FALSE; setnames(d,fields)
    if(nrow(d)) FUN(d)
  }
  repeat {
    next_bytes <- readBin(con,"raw",n=as.integer(chunk_bytes)); if(!length(next_bytes)) break
    bytes <- c(carry,next_bytes); lf <- which(bytes==as.raw(10L)); quotes <- which(bytes==as.raw(34L))
    bounds <- lf[findInterval(lf,quotes) %% 2L == 0L]
    if(!length(bounds)) {carry<-bytes; if(length(carry)>64L*1024L*1024L)stop("Oversized CSV record"); next}
    cut <- tail(bounds,1); consume(bytes[seq_len(cut)])
    carry <- if(cut<length(bytes))bytes[seq.int(cut+1L,length(bytes))] else raw()
  }
  if(length(carry)) {stopifnot(sum(carry==as.raw(34L))%%2L==0L);consume(carry)}
  invisible(NULL)
}

build_episodes <- function(cfg,hospital,con) {
  root <- file.path(cfg$input_root,hospital)
  # AHMU SEX is GB18030: the bytes for 女 are also valid UTF-8, so guessing is unsafe.
  demo <- read_small(file.path(root,"01.csv"),c(KEY,"AGE","SEX","BMI"),hospital=="AHMU",
                     field_encodings=if(hospital=="AHMU")c(SEX="GB18030") else character())
  # AHMU OPERATION_SCALE also contains GB18030 bytes valid as different UTF-8 text.
  oper <- read_small(file.path(root,"03.csv"),c(KEY,"START_DATE_TIME","ANES_START_TIME","IN_DATE_TIME","ASA_GRADE","EMERGENCY_INDICATOR","OPERATION_SCALE","OPERATING_DEPT"),hospital=="AHMU",
                     field_encodings=if(hospital=="AHMU")c(OPERATION_SCALE="GB18030") else character())
  ward <- read_small(file.path(root,"13.csv"),c(KEY,"IN_HOSPITAL_TIME","OUT_HOSPITAL_TIME","IN_ICU_TIME","OUT_ICU_TIME"),hospital=="AHMU")
  raw_n <- nrow(oper)
  complete <- function(d) Reduce(`&`,lapply(KEY,function(k)!is.na(d[[k]]) & nzchar(d[[k]])))
  incomplete_n <- sum(!complete(oper)); oper <- oper[complete(oper)]
  before_unique <- nrow(oper)
  oper <- unique(oper,by=KEY); demo <- unique(demo[complete(demo)],by=KEY); ward <- unique(ward[complete(ward)],by=KEY)
  stopifnot(!any(vapply(KEY,function(k)any(grepl("|",oper[[k]],fixed=TRUE)),logical(1))))
  demo[, DEMO_MATCH := TRUE]; ward[, WARD_MATCH := TRUE]
  ep <- merge(merge(oper,demo,by=KEY,all.x=TRUE),ward,by=KEY,all.x=TRUE)
  stopifnot(nrow(ep)==nrow(oper))
  ep[, `:=`(source=hospital,episode_id=paste(PATIENT_ID,VISIT_ID,OPER_ID,sep="|"),age=number(AGE),sex=clean_sex(SEX),bmi=number(BMI),asa=clean_asa(ASA_GRADE),emergency=number(EMERGENCY_INDICATOR))]
  ep[age<0 | age>110,age:=NA_real_]
  database_fields <- c(KEY,cfg$operation_time_priority,"IN_HOSPITAL_TIME","OUT_HOSPITAL_TIME","IN_ICU_TIME","OUT_ICU_TIME","source","episode_id","age","sex","bmi","asa","emergency","OPERATION_SCALE","OPERATING_DEPT")
  phase <<- "episode_database_write"
  dbWriteTable(con,"episode_input",as.data.frame(ep[,..database_fields]),temporary=TRUE,overwrite=TRUE)
  parsed <- paste(c(paste0("coalesce(",paste(vapply(cfg$operation_time_priority,ts_expr,character(1)),collapse=","),") AS parsed_t0"),
                   paste0(vapply(c("IN_HOSPITAL_TIME","OUT_HOSPITAL_TIME","IN_ICU_TIME","OUT_ICU_TIME"),ts_expr,character(1))," AS ",c("h_in","h_out","i_in","i_out"))),collapse=",")
  phase <<- "episode_time_mapping"
  # User-confirmed: no valid ICU admission timestamp means unknown, not an observed absence.
  dbExecute(con,paste0("CREATE OR REPLACE TEMP TABLE episodes AS WITH p AS (SELECT *,",parsed," FROM episode_input), q AS (SELECT *,date_diff('microsecond',h_in,h_out)/86400000000.0 AS hosp_days FROM p) SELECT source,episode_id,PATIENT_ID AS patient_id,VISIT_ID AS visit_id,OPER_ID AS oper_id,parsed_t0 AS time_zero,",time_string("parsed_t0")," AS t0,age,sex,bmi,asa,emergency,OPERATION_SCALE AS operation_scale,OPERATING_DEPT AS department,CASE WHEN hosp_days<0 OR hosp_days>365 THEN NULL ELSE hosp_days END AS hosp_los_days,date_diff('microsecond',i_in,i_out)/86400000000.0 AS icu_los_days,CASE WHEN i_in IS NOT NULL THEN 1 ELSE CAST(NULL AS INTEGER) END AS icu_admitted,date_diff('microsecond',parsed_t0,h_out)/86400000000.0 AS discharge_t_days,CAST(NULL AS DOUBLE) AS death_t_days,CAST(NULL AS INTEGER) AS died_inhosp FROM q"))
  cov <- as.data.table(dbGetQuery(con,paste0("SELECT ",paste(EPISODE_FIELDS,collapse=",")," FROM episodes ORDER BY episode_id")))
  stopifnot(identical(names(cov),EPISODE_FIELDS),uniqueN(cov$episode_id)==nrow(cov),all(nzchar(cov$patient_id)))
  qa <- list(raw_operations=raw_n,excluded_incomplete_keys=incomplete_n,duplicate_complete_operation_rows_removed=before_unique-nrow(oper),episodes=nrow(cov),patients=uniqueN(cov$patient_id),
             demographics_matches=sum(ep$DEMO_MATCH %in% TRUE),ward_matches=sum(ep$WARD_MATCH %in% TRUE),
             missing_t0=sum(is.na(cov$t0)),year_counts=cov[,.(rows=.N),by=.(year=substr(t0,1,4))][order(year)])
  list(data=cov,qa=qa)
}

collect_candidates <- function(cfg,hospital,con) {
  fields <- c("PATIENT_ID","REPORT_ITEM_NAME","RESULT","UNITS","SPECIMEN",cfg$lab_time_priority)
  paths <- lab_files(cfg$input_root,hospital)
  parts <- list(); scanned <- 0
  {
    phase <<- "make_encoding_patterns"
    byte_pattern <- function(x,encoding) {v<-iconv(enc2utf8(x),from="UTF-8",to=encoding);Encoding(v)<-"unknown";v}
    patterns <- c(byte_pattern("肌酐","UTF-8"),byte_pattern("肌酐","GB18030"))
    next_log <- 2000000
    for(p in paths) read_selected_chunks(p,fields,function(d) {
      phase <<- "select_creatinine_candidates"
      scanned <<- scanned+nrow(d)
      item <- d$REPORT_ITEM_NAME
      selected <- grepl(patterns[1],item,fixed=TRUE,useBytes=TRUE)|grepl(patterns[2],item,fixed=TRUE,useBytes=TRUE)|grepl("creat",item,ignore.case=TRUE,useBytes=TRUE)
      if(any(selected)) {
        keep <- d[selected]
        for(k in names(keep)) {phase <<- paste0("decode_",k);set(keep,j=k,value=gsub('""','"',decode_mixed(keep[[k]]),fixed=TRUE))}
        parts[[length(parts)+1L]] <<- keep
      }
      if(scanned>=next_log){message(hospital," laboratory rows scanned: ",scanned);next_log<<-next_log+2000000}
    })
  }
  d <- rbindlist(parts,use.names=TRUE); rm(parts); gc(FALSE)
  phase <<- "filter_creatinine_candidates"
  d[, PATIENT_ID := unq(PATIENT_ID)]
  for(k in c("REPORT_ITEM_NAME","UNITS","SPECIMEN"))d[is.na(get(k)),(k):=""]
  groups <- d[,.(rows=.N),by=.(item=REPORT_ITEM_NAME,unit=UNITS,specimen=SPECIMEN)][order(-rows)]
  excluded_name <- grepl(cfg$nonserum_name_pattern,d$REPORT_ITEM_NAME,ignore.case=TRUE)
  excluded_specimen <- grepl(cfg$nonserum_specimen_pattern,d$SPECIMEN,ignore.case=TRUE)
  raw_unit <- tolower(gsub("[[:space:]]","",d$UNITS))
  unit_key <- gsub("[^a-z0-9]","",gsub("µ|μ","u",raw_unit))
  recognized <- unit_key %chin% c("umoll","mgdl")
  d[, raw_value := number(RESULT)]
  d[, value_umol := fifelse(unit_key=="mgdl",raw_value*cfg$umol_per_mgdl,raw_value)]
  allowed <- !excluded_name & !excluded_specimen & recognized & !is.na(d$raw_value) & d$value_umol>cfg$min_umol_exclusive & d$value_umol<cfg$max_umol_exclusive & !is.na(d$PATIENT_ID) & nzchar(d$PATIENT_ID)
  allowed[is.na(allowed)] <- FALSE
  qa <- list(laboratory_source_rows_scanned=scanned,candidate_rows=nrow(d),candidate_groups=groups,excluded_nonserum_name_or_specimen=sum(excluded_name|excluded_specimen),
             excluded_unknown_units_after_serum_filter=sum(!excluded_name & !excluded_specimen & !recognized),
             rows_after_identity_unit_and_value_filters=sum(allowed))
  keep <- d[allowed,c("PATIENT_ID",cfg$lab_time_priority,"value_umol"),with=FALSE]
  dbWriteTable(con,"creatinine_input",as.data.frame(keep),temporary=TRUE,overwrite=TRUE)
  date_expressions <- vapply(cfg$lab_time_priority,ts_expr,character(1))
  dbExecute(con,paste0("CREATE OR REPLACE TEMP TABLE creatinine AS SELECT PATIENT_ID AS patient_id,value_umol,coalesce(",paste(date_expressions,collapse=","),") AS lab_time FROM creatinine_input"))
  qa$valid_time_rows <- dbGetQuery(con,"SELECT count(*) AS n FROM creatinine WHERE lab_time IS NOT NULL")$n
  qa$time_priority_counts <- dbGetQuery(con,paste0("SELECT CASE WHEN ",date_expressions[1]," IS NOT NULL THEN 'specimen_received' WHEN ",date_expressions[2]," IS NOT NULL THEN 'result' WHEN ",date_expressions[3]," IS NOT NULL THEN 'report' ELSE 'missing' END AS chosen_time,count(*) AS rows FROM creatinine_input GROUP BY 1 ORDER BY 1"))
  qa
}
