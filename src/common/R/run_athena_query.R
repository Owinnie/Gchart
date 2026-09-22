run_athena_query <- function(db = "powerbi", query) {

  library(noctua)
  library(yaml)

  source(paste0(Sys.getenv("path_common"), "R/athena_config.R"))

  # load file with secrets
  secret_yaml_file_path <- Sys.getenv("secret_yaml_file_path")
  config <- yaml::read_yaml(secret_yaml_file_path, readLines.warn = FALSE)

  # Settings -----
  # Prefer AWS_REGION from .Renviron over secrets.yaml. The previous
  # Airflow failure kept using secrets.yaml region_name, so setting
  # AWS_REGION=eu-central-1 had no effect on the noctua connection.
  aws_access_key_id <- config$scripts$aws$access_key_id
  aws_secret_access_key <- config$scripts$aws$secret_access_key
  aws_session_token <- config$scripts$aws$session_token
  region_name <- resolve_athena_region(config$scripts$aws$region_name)
  s3_staging_dir <- resolve_athena_s3_staging_dir(db = db)
  workgroup <- Sys.getenv("athena_workgroup", unset = "")

  # Keep paws/noctua and any other AWS SDK calls on the same region.
  Sys.setenv(AWS_REGION = region_name, AWS_DEFAULT_REGION = region_name)
  Sys.setenv(AWS_ATHENA_S3_STAGING_DIR = s3_staging_dir)

  message(
    "Athena connection: region=", region_name,
    ", s3_staging_dir=", s3_staging_dir,
    if (nzchar(workgroup)) paste0(", workgroup=", workgroup) else "",
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
    bigint = "integer" # bigint avoids "int64" type
  )

  # 2. Conditionally add aws_session_token when using temporary credentials
  # Check if the token exists and is not an empty string
  if (!is.null(aws_session_token) && nchar(aws_session_token) > 0) {
    args$aws_session_token <- aws_session_token
  }

  # Only attach a workgroup when one is configured. Forcing "primary"
  # can ignore s3_staging_dir if that workgroup enforces its own
  # output location (this is how leftover katrin-test can reappear).
  if (nzchar(workgroup)) {
    args$work_group <- workgroup
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
      " (region=", region_name, ", s3_staging_dir=", s3_staging_dir, ") --> ",
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
          " (region=", region_name, ", s3_staging_dir=", s3_staging_dir, "): ",
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
          " (region=", region_name, ", s3_staging_dir=", s3_staging_dir, "): ",
          as.character(exec_result)[1],
          call. = FALSE
        )
      }
      return(invisible(TRUE))
    }
  }

} # end of function
