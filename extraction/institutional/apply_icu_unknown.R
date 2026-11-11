invisible(Sys.setlocale("LC_CTYPE", ".UTF-8"))
args<-commandArgs(trailingOnly=TRUE)
this_file<-sub("^--file=","",commandArgs(FALSE)[grepl("^--file=",commandArgs(FALSE))][1])
script_dir<-dirname(normalizePath(this_file,winslash="/",mustWork=TRUE))
source(file.path(script_dir,"helpers.R"),encoding="UTF-8")
source(file.path(script_dir,"config.R"),encoding="UTF-8")
phase<-"arguments"
dir.create(cfg$audit_root,recursive=TRUE,showWarnings=FALSE)

same_covariates<-function(a,b,skip=character()) {
  numeric_fields<-c("age","bmi","asa","emergency","hosp_los_days","icu_los_days","icu_admitted","discharge_t_days","death_t_days","died_inhosp")
  for(k in setdiff(names(a),skip)) {
    x<-a[[k]];y<-b[[k]]
    if(k %chin% numeric_fields) {
      x<-number(x);y<-number(y)
      ok<-(is.na(x)&is.na(y))|(!is.na(x)&!is.na(y)&abs(x-y)<=1e-9+1e-12*pmax(abs(x),abs(y)))
    } else {
      x<-as.character(x);y<-as.character(y);x[is.na(x)]<-"";y[is.na(y)]<-"";ok<-x==y
    }
    ok[is.na(ok)]<-FALSE;stopifnot(all(ok))
  }
}

stage_icu<-function(path,staged,old,desired) {
  changed<-which(old$icu_admitted!=desired)
  stopifnot(length(changed)>0L,all(old$icu_admitted[changed]=="0"),all(desired[changed]==""))
  con<-file(path,"rb");bytes<-readBin(con,"raw",n=file.info(path)$size);close(con)
  quotes<-which(bytes==as.raw(34L));stopifnot(length(quotes)%%2L==0L)
  commas<-which(bytes==as.raw(44L));commas<-commas[findInterval(commas,quotes)%%2L==0L]
  lines<-which(bytes==as.raw(10L));lines<-lines[findInterval(lines,quotes)%%2L==0L]
  stopifnot(length(commas)==(nrow(old)+1L)*(ncol(old)-1L),
    all(tabulate(findInterval(commas,lines)+1L,nbins=nrow(old)+1L)==ncol(old)-1L))
  separators<-matrix(commas,ncol=ncol(old)-1L,byrow=TRUE);j<-match("icu_admitted",names(old))
  starts<-separators[changed+1L,j-1L]+1L;ends<-separators[changed+1L,j]-1L
  bare<-ends==starts & bytes[starts]==as.raw(48L)
  quoted<-ends==starts+2L & bytes[starts]==as.raw(34L) & bytes[ends]==as.raw(34L) & bytes[starts+1L]==as.raw(48L)
  stopifnot(all(bare|quoted))
  remove<-starts+as.integer(quoted)
  out<-file(staged,"wb");writeBin(bytes[-remove],out);close(out)
  rm(bytes,commas,quotes,separators);invisible(gc(FALSE))
  fixed<-safe_fread(staged,encoding="UTF-8",colClasses="character",na.strings=NULL,showProgress=FALSE)
  stopifnot(nrow(fixed)==nrow(old),identical(names(fixed),names(old)),identical(fixed$icu_admitted,desired),
    all(vapply(setdiff(names(old),"icu_admitted"),function(k)identical(old[[k]],fixed[[k]]),logical(1))))
  invisible(NULL)
}

run<-function() {
  stopifnot(length(args)==1L,args[1] %chin% c("--validate-only","--apply"))
  validation_path<-file.path(cfg$audit_root,"icu_validation.json")
  root<-normalizePath(cfg$existing_output_root,winslash="/",mustWork=TRUE)
  source_paths<-unlist(lapply(cfg$cohorts,function(h)file.path(cfg$input_root,h,c("01.csv","03.csv","13.csv"))))
  cov_paths<-setNames(file.path(root,paste0(cfg$cohorts,"_episode_covariates.csv")),cfg$cohorts)
  series_paths<-file.path(root,paste0(cfg$cohorts,"_creatinine_series.csv"))
  tracked<-c(source_paths,unname(cov_paths),series_paths);before<-metadata(tracked)
  summaries<-list();plans<-list()
  for(h in cfg$cohorts) {
    phase<<-paste0("validate_",h);message("VALIDATING ICU RULE ",h)
    con<-new_connection();expected<-build_episodes(cfg,h,con)$data;dbDisconnect(con,shutdown=TRUE)
    old<-safe_fread(cov_paths[[h]],encoding="UTF-8",colClasses="character",na.strings=NULL,showProgress=FALSE)
    stopifnot(identical(names(old),EPISODE_FIELDS),nrow(old)==nrow(expected),uniqueN(old$episode_id)==nrow(old))
    pos<-match(old$episode_id,expected$episode_id);stopifnot(!anyNA(pos));expected<-expected[pos]
    same_covariates(old,expected,skip="icu_admitted")
    desired<-as.character(expected$icu_admitted);desired[is.na(desired)]<-""
    changed<-which(old$icu_admitted!=desired)
    stopifnot(length(changed)>0L,all(old$icu_admitted %chin% c("0","1")),
      all(desired %chin% c("","1")),all(old$icu_admitted[changed]=="0"),all(desired[changed]==""),
      identical(which(old$icu_admitted=="1"),which(desired=="1")),
      nrow(old)==expected_current_counts[[h]][["covariates_rows"]])
    summaries[[h]]<-list(rows=nrow(old),patients=uniqueN(old$patient_id),changed_zero_to_missing=length(changed),
      retained_icu_admitted_1=sum(desired=="1"),unknown_after=sum(desired==""),other_fields_changed=0L)
    plans[[h]]<-list(old=old,desired=desired)
    rm(old,expected,con,pos);invisible(gc(FALSE))
  }
  stopifnot(identical(before,metadata(tracked)))
  result<-list(status="PASS",rule="Valid ICU admission timestamp -> 1; no valid timestamp -> missing",mode=args[1],
    cohorts=summaries,inputs=before,only_changed_field="icu_admitted",clinical_time_fields_changed=FALSE,
    creatinine_files_changed=FALSE,rows_changed=0L)
  if(args[1]=="--validate-only") {
    write_json(result,validation_path,pretty=TRUE,auto_unbox=TRUE,na="null",digits=16)
    cat(toJSON(result[setdiff(names(result),"inputs")],auto_unbox=TRUE),"\n");return(invisible(NULL))
  }
  phase<<-"validated_input_gate"
  prior<-fromJSON(validation_path)
  stopifnot(prior$status=="PASS",identical(before$path,prior$inputs$path),
    all(before$bytes==prior$inputs$bytes),all(abs(before$mtime-prior$inputs$mtime)<.01))
  staged<-setNames(paste0(unname(cov_paths),".icu_unknown.pending"),cfg$cohorts)
  backup_root<-file.path(root,"修正前备份_20261108_ICU未知")
  backups<-setNames(file.path(backup_root,basename(cov_paths)),cfg$cohorts)
  stopifnot(all(startsWith(c(staged,backups),paste0(root,"/"))),!any(file.exists(staged)),!any(file.exists(backups)))
  for(h in cfg$cohorts) {
    phase<<-paste0("stage_",h)
    stage_icu(cov_paths[[h]],staged[[h]],plans[[h]]$old,plans[[h]]$desired)
  }
  stopifnot(identical(before,metadata(tracked)))
  phase<<-"activate_with_backups"
  dir.create(backup_root,recursive=FALSE,showWarnings=FALSE)
  moved<-character()
  tryCatch({
    for(h in cfg$cohorts) {
      stopifnot(file.rename(cov_paths[[h]],backups[[h]]));moved<-c(moved,h)
      stopifnot(file.rename(staged[[h]],cov_paths[[h]]))
    }
  },error=function(e) {
    for(h in rev(moved)) {
      if(file.exists(cov_paths[[h]]))file.rename(cov_paths[[h]],staged[[h]])
      file.rename(backups[[h]],cov_paths[[h]])
    }
    stop("Activation failed; prior exports restored where possible",call.=FALSE)
  })
  phase<<-"verify_active_exports"
  for(h in cfg$cohorts) {
    active<-safe_fread(cov_paths[[h]],encoding="UTF-8",colClasses="character",na.strings=NULL,showProgress=FALSE)
    stopifnot(identical(active$icu_admitted,plans[[h]]$desired),
      all(vapply(setdiff(names(active),"icu_admitted"),function(k)identical(active[[k]],plans[[h]]$old[[k]]),logical(1))))
  }
  unchanged_paths<-c(source_paths,series_paths)
  unchanged_before<-before[match(unchanged_paths,before$path),,drop=FALSE];rownames(unchanged_before)<-NULL
  stopifnot(identical(unchanged_before,metadata(unchanged_paths)))
  result$status<-"VERIFIED_COMPLETE";result$backup_root<-backup_root
  result$source_and_creatinine_files_unchanged<-TRUE
  result$completed_at<-format(Sys.time(),"%Y-%m-%d %H:%M:%S %z")
  write_json(result,file.path(cfg$audit_root,"icu_completed.json"),pretty=TRUE,auto_unbox=TRUE,na="null",digits=16)
  cat(toJSON(result[setdiff(names(result),"inputs")],auto_unbox=TRUE),"\n")
}
tryCatch(run(),error=function(e) {
  result<-list(status="FAIL",phase=phase,message="Patient details suppressed")
  write_json(result,file.path(cfg$audit_root,"icu_error.json"),pretty=TRUE,auto_unbox=TRUE)
  cat(toJSON(result,auto_unbox=TRUE),"\n");quit(status=1L)
})
