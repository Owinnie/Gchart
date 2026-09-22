run_athena_query <- function(db = "powerbi", query) {

  library(noctua)
  library(yaml)

  source(paste0(Sys.getenv("path_common"), "R/athena_config.R"))

  # load file with secrets
  secret_yaml_file_path <- Sys.getenv("secret_yaml_file_path")
  config <- yaml::read_yaml(secret_yaml_file_path, readLines.warn = FALSE)

  # Settings -----
  # Prefer AWS_REGION from .Renviron over secrets.yaml. noctua used to
  # take region_name from secrets.yaml, so AWS_REGION=eu-central-1 had
  # no effect. katrin-test / workgroup primary are eu-central-1 only.
  aws_access_key_id <- config$scripts$aws$access_key_id
  aws_secret_access_key <- config$scripts$aws$secret_access_key
  aws_session_token <- config$scripts$aws$session_token
  s3_staging_dir <- resolve_athena_s3_staging_dir(db = db)
  region_name <- resolve_athena_region(
    config$scripts$aws$region_name,
    staging_uri = s3_staging_dir
  )
  workgroup <- Sys.getenv("athena_workgroup", unset = "")
  if (!nzchar(workgroup)) {
    # s3_data_lake.reader.dev is scoped to workgroup/primary.
    workgroup <- "primary"
  }

  # Keep paws/noctua and any other AWS SDK calls on the same region.
  Sys.setenv(AWS_REGION = region_name, AWS_DEFAULT_REGION = region_name)
  Sys.setenv(AWS_ATHENA_S3_STAGING_DIR = s3_staging_dir)
  Sys.setenv(AWS_ATHENA_WORK_GROUP = workgroup)

  message(
    "Athena connection: region=", region_name,
    ", s3_staging_dir=", s3_staging_dir,
    ", workgroup=", workgroup,
    ", schema=", db
  )

  # connect to athena
  # 1. Prepare base arguments for dbConnect
  args <- list(
    drv = noctua::athena(),
    aws_access_key_id = aws_access_key_id,
    aws_secret_access_key = aws_secret_access_key,
    s3_staging_dir = s3_staging_dir,
    region_name = region_name,
    schema_name = db,
    work_group = workgroup,
    bigint = "integer" # bigint avoids "int64" type
  )

  # 2. Conditionally add aws_session_token when using temporary credentials
  # Check if the token exists and is not an empty string
  if (!is.null(aws_session_token) && nchar(aws_session_token) > 0) {
    args$aws_session_token <- aws_session_token
  }

  # 3. Connect to athena using do.call to pass the list of arguments
  con <- try(
    do.call(DBI::dbConnect, args),
    silent = TRUE
  )

  # try to connect again with 2nd try if necessary
  if (inherits(con, "try-error")) { # try a 2nd time
    # wait 5 seconds
    Sys.sleep(5)

    con <- try(
      do.call(DBI::dbConnect, args),
      silent = TRUE
    )
  }

  # if still error return error
  if (inherits(con, "try-error")) {

    message(paste0(
      "Can not establish connection with Athena ", db,
      " (region=", region_name, ", s3_staging_dir=", s3_staging_dir,
      ", workgroup=", workgroup, ") --> ",
      con[1]
    ))
    return(NULL)
  } else {

    # close connection on exit of function, also in case of error
    on.exit(DBI::dbDisconnect(con))

    # Route based on query type
    if (grepl("^\\s*(SELECT|WITH)\\b", query, ignore.case = TRUE)) {
      query_results <- try(DBI::dbGetQuery(con, query), silent = TRUE)
      if (inherits(query_results, "try-error")) {
        stop(
          "Athena query failed for ", db,
          " (region=", region_name, ", s3_staging_dir=", s3_staging_dir,
          ", workgroup=", workgroup, "): ",
          as.character(query_results)[1],
          call. = FALSE
        )
      }
      return(query_results)
    } else {
      # DDL / utility (MSCK REPAIR, CREATE, DROP, ...)
      exec_result <- try(DBI::dbExecute(con, query), silent = TRUE)
      if (inherits(exec_result, "try-error")) {
        stop(
          "Athena statement failed for ", db,
          " (region=", region_name, ", s3_staging_dir=", s3_staging_dir,
          ", workgroup=", workgroup, "): ",
          as.character(exec_result)[1],
          call. = FALSE
        )
      }
      return(invisible(TRUE))
    }
  }

} # end of function
