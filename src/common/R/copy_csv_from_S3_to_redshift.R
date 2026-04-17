copy_csv_from_S3_to_redshift <- function(db_name, schema, table_name, s3_bucket, s3_path, filename, overwrite = TRUE, redshift_type) {

  library(RPostgres)
  library(yaml)

  source(paste0(Sys.getenv("path_common"), "R/get_redshift_connection.R"))

  # load file with secrets
  secret_yaml_file_path <- Sys.getenv("secret_yaml_file_path")
  config <- yaml::read_yaml(secret_yaml_file_path, readLines.warn = FALSE)

  con <- get_redshift_connection(db_name = db_name, redshift_type = redshift_type)
  if (!inherits(con, "DBIConnection")) {
    stop("Failed to get a valid Redshift DBI connection.")
  }

  # close connection on exit of function, also in case of error
  on.exit(DBI::dbDisconnect(con))

  if (overwrite) {
    # truncate tables before copying, since COPY statement appends to table
    RPostgres::dbExecute(con, paste0("truncate table ", schema, ".", table_name))
  }

  # Settings -----
  if (redshift_type == "ondemand") {
    iam_role_copy_s3 <- config$scripts$aws$redshift$ondemand$iam_role_copy_s3
  } else if (redshift_type == "serverless") {
    iam_role_copy_s3 <- config$scripts$aws$redshift$serverless$iam_role_copy_s3
  } else {
    stop("Invalid Redshift type. Please specify either 'ondemand' or 'serverless'.")
  }

  # copy table from S3
  RPostgres::dbExecute(
    con,
    paste0(
      "COPY ", schema, ".", table_name, "
       FROM 's3://", s3_bucket, "/", s3_path, "/", filename, ".csv'
       IAM_ROLE '", iam_role_copy_s3, "'
       CSV
       IGNOREHEADER 1
       DELIMITER ','
       NULL AS ''
       TRUNCATECOLUMNS"
    )
  )
}
