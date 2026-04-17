write_to_s3_datalake <- function(df, filename, db_name, schema, redshift_type = "ondemand", overwrite = TRUE) {

  # =================================================================
  # 1. LEGACY REDSHIFT UPLOAD (CSV STAGING)
  # =================================================================
  # write data to S3 (staging for Redshift) ----
  source(paste0(Sys.getenv("path_common"), "R/write_to_S3.R"))

  write_to_S3(
    dataframe = df,
    filename = filename,
    s3_bucket = Sys.getenv("s3_to_redshift_bucket"),
    s3_path = Sys.getenv("s3_to_redshift_path")
  )

  # then copy from S3 to Redshift -----
  source(paste0(Sys.getenv("path_common"), "R/copy_csv_from_S3_to_redshift.R"))

  copy_csv_from_S3_to_redshift(
    db_name = db_name,
    schema = schema,
    table_name = filename,
    s3_bucket = Sys.getenv("s3_to_redshift_bucket"),
    s3_path = Sys.getenv("s3_to_redshift_path"),
    filename = filename,
    overwrite = overwrite,
    redshift_type = redshift_type
  )

  # =================================================================
  # 2. NEW AUTOMATED S3 DATA LAKE UPLOAD (PARQUET)
  # =================================================================
  tryCatch({
    message("Starting automated S3 Data Lake upload for: ", filename)

    require(arrow, quietly = TRUE)
    require(yaml, quietly = TRUE)
    require(dplyr, quietly = TRUE)
    require(bit64, quietly = TRUE)
    require(lubridate, quietly = TRUE)

    # ===============================================================
    # THE SCHEMA FIXER: Standardize data types for Parquet
    # ===============================================================
    df <- df %>%
      mutate(
        # 1. Fix Dates: Find columns ending in "_at" or "date".
        # If they are strings, convert them back to native timestamps.
        across(matches("_at$|date$"), ~ if (is.character(.x)) lubridate::as_datetime(.x) else .x),

        # 2. Fix IDs: Find columns ending in "_id".
        # Force them to 64-bit integers to match Redshift's BIGINT.
        across(ends_with("_id"), ~ bit64::as.integer64(.x))
      )
    # ===============================================================

    s3_bucket_lake <- Sys.getenv("s3_data_lake_bucket")
    s3_base_prefix <- paste0(schema, "/", filename, "/")

    if (overwrite == TRUE) {
      # OVERWRITE STRATEGY: Single data.parquet file
      s3_full_prefix <- s3_base_prefix
      parquet_name <- "data.parquet"
    } else {
      # APPEND STRATEGY: Partitioned by year/month with timestamped files
      run_date <- Sys.Date()
      s3_full_prefix <- paste0(
        s3_base_prefix,
        "year=", format(run_date, "%Y"),
        "/month=", format(run_date, "%m"), "/"
      )
      parquet_name <- paste0("data_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".parquet")
    }

    # Grab S3 Credentials
    secret_yaml_file_path <- Sys.getenv("secret_yaml_file_path")
    config <- yaml::read_yaml(secret_yaml_file_path, readLines.warn = FALSE)

    Sys.setenv(
      AWS_ACCESS_KEY_ID = config$scripts$aws$access_key_id,
      AWS_SECRET_ACCESS_KEY = config$scripts$aws$secret_access_key,
      AWS_DEFAULT_REGION = config$scripts$aws$region_name
    )

    # WRITE DIRECTLY TO S3 (No local files)
    s3_uri <- paste0("s3://", s3_bucket_lake, "/", s3_full_prefix, parquet_name)
    arrow::write_parquet(df, s3_uri)

    message("Successfully uploaded Parquet to Data Lake: ", s3_full_prefix, parquet_name)
  }, error = function(e) {
    # If S3 fails, print a warning but don't crash the Redshift pipeline
    warning("Automated S3 Data Lake Upload failed for ", filename, ": ", e$message)
  })
}
