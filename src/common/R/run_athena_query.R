# connect to and query from AWS Athena tables
#
# Return-value contract (important for callers):
#   * connection failure ................ returns NULL
#   * SELECT / WITH (data retrieval) .... returns a data.frame with the rows
#   * DDL / utility (MSCK REPAIR, CREATE,
#     DROP, ...) that executed OK ....... returns invisible(TRUE)
#
# Callers can therefore treat a NULL result as "could not connect / query
# failed" and anything non-NULL as success. Previously DDL/utility queries
# returned invisible(NULL) on success, which was indistinguishable from a
# connection failure and caused successful "MSCK REPAIR" runs to be reported
# as "could not connect to Athena".

run_athena_query <- function(
                       db = "lecturio_bi_data",
                       query,
                       secrets_path = "aws",
                       s3_staging_dir = paste0(Sys.getenv("s3_staging_dir"), db, "/"),
                       workgroup = "primary"){

  library(noctua)

  # load file with secrets
  secret_yaml_file_path <- Sys.getenv("secret_yaml_file_path")
  config <- yaml::read_yaml(secret_yaml_file_path, readLines.warn = FALSE)
  source(paste0(Sys.getenv("path_common"), "R/aws_utils.R"))
  creds <- resolve_aws_secrets(config, secrets_path)

  # Settings -----
  s3_staging_dir <- s3_staging_dir
  workgroup <- workgroup
  aws_access_key_id <- creds$access_key_id
  aws_secret_access_key <- creds$secret_access_key
  region_name <- creds$region_name
  aws_session_token <- creds$session_token

  # connect to athena
  # 1. Prepare base arguments for dbConnect
  args <- list(
    drv = noctua::athena(),
    aws_access_key_id = aws_access_key_id,
    aws_secret_access_key = aws_secret_access_key,
    s3_staging_dir = s3_staging_dir,
    region_name = region_name,
    schema_name = db,
    bigint = "integer", # bigint avoids "int64" type
    work_group = workgroup
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
  if (inherits(con, "try-error")) {# try a 2nd time
    # wait 5 seconds
    Sys.sleep(5)

    con <- try(
      do.call(DBI::dbConnect, args),
      silent = TRUE
    )
  }

  # if still error return error
  if (inherits(con, "try-error")) {

    message(paste0("Can not establish connection with Athena ", db, " --> ", con[1]))
    return(NULL)

  } else {

    # close connection on exit of function, also in case of error
    on.exit(dbDisconnect(con))

    # Route based on query type
    if (grepl("^\\s*(SELECT|WITH)\\b", query, ignore.case = TRUE)) {
      # For data retrieval queries
      query_results <- DBI::dbGetQuery(con, query)
      return(query_results)
    } else {
      # For DDL/Utility queries (MSCK REPAIR, CREATE, DROP, etc.)
      # Returning a non-NULL value on success lets callers distinguish a
      # successful execution from a failed connection (which returns NULL).
      DBI::dbExecute(con, query)
      return(invisible(TRUE))
    }
  }

} # end of function
