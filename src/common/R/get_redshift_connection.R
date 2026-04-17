get_redshift_connection <- function(db_name, redshift_type = "ondemand") {

  # db_name: name of the database, usually datateam or dev
  # redshift_type: type of redshift, either ondemand or serverless

  library(RPostgres)
  library(yaml)

  # load file with secrets
  secret_yaml_file_path <- Sys.getenv("secret_yaml_file_path")
  config <- yaml::read_yaml(secret_yaml_file_path, readLines.warn = FALSE)

  # Settings -----
  if (redshift_type == "ondemand") {
    url <- config$scripts$aws$redshift$ondemand$url
    port <- config$scripts$aws$redshift$ondemand$port
    user <- config$scripts$aws$redshift$ondemand$user
    password <- config$scripts$aws$redshift$ondemand$password
  } else if (redshift_type == "serverless") {
    url <- config$scripts$aws$redshift$serverless$url
    port <- config$scripts$aws$redshift$serverless$port
    user <- config$scripts$aws$redshift$serverless$user
    password <- config$scripts$aws$redshift$serverless$password
  } else {
    stop("Invalid Redshift type. Please specify either 'ondemand' or 'serverless'.")
  }

  connect_once <- function() {
    try(
      DBI::dbConnect(
        RPostgres::Redshift(),
        dbname = db_name,
        user = user,
        password = password,
        host = url,
        port = port,
        bigint = "integer"
      ),
      silent = TRUE
    )
  }

  con <- connect_once()

  # try to connect again with 2nd try if necessary
  if (class(con) == "try-error") {
    # wait 5 seconds
    Sys.sleep(5)

    con <- connect_once()
  }

  # fail fast with a typed error, never return a character connection
  if (class(con) == "try-error") {
    stop(paste0(
      "Can not establish connection with Redshift ", db_name, ": ",
      as.character(con)[1]
    ))
  } else {
    return(con)
  }
}
