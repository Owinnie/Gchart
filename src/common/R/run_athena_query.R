run_athena_query <- function(db = "powerbi", query) {

  library(noctua)
  library(yaml)

  # load file with secrets
  secret_yaml_file_path <- Sys.getenv("secret_yaml_file_path")
  config <- yaml::read_yaml(secret_yaml_file_path, readLines.warn = FALSE)

  # Settings -----
  aws_access_key_id <- config$scripts$aws$access_key_id
  aws_secret_access_key <- config$scripts$aws$secret_access_key
  s3_staging_dir <- paste0(Sys.getenv("s3_staging_dir"), db, "/")
  region_name <- config$scripts$aws$region_name
  aws_session_token <- config$scripts$aws$session_token

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

  # 3. Connect to athena using do.call to pass the list of arguments
  con <- try(
    do.call(DBI::dbConnect, args),
    silent = TRUE
  )

  # try to connect again with 2nd try if necessary
  if (class(con) == "try-error") { # try a 2nd time
    # wait 5 seconds
    Sys.sleep(5)

    con <- try(
      do.call(DBI::dbConnect, args),
      silent = TRUE
    )
  }

  # if still error return error
  if (class(con) == "try-error") {

    message(paste0("Can not establish connection with Athena ", db, " --> ", con[1]))
    return(NULL)
  } else {

    # close connection on exit of function, also in case of error
    on.exit(DBI::dbDisconnect(con))

    # pull the data
    query_results <- DBI::dbGetQuery(con, query)
    return(query_results)
  }

} # end of function
