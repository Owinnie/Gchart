#!/usr/bin/env Rscript

# Bootstrap Redshift schema tables into S3 data lake.
# Strategy:
# - Detect append vs overwrite from SOURCE S3 layout:
#   - keys containing "year=" and "month=" => append
#   - otherwise => overwrite
# - Append tables: unload historical data (< CURRENT_DATE) partitioned by year/month.
# - Overwrite tables: unload current snapshot (single, non-partitioned prefix).
# - Skip tables that already have objects in target S3 prefix.

source(paste0(Sys.getenv("path_common"), "R/get_redshift_connection.R"))

suppressPackageStartupMessages({
  library(DBI)
  library(yaml)
  library(glue)
})

schema_name <- Sys.getenv("BOOTSTRAP_SCHEMA", "powerbi")
db_name <- Sys.getenv("BOOTSTRAP_DB_NAME", Sys.getenv("powerbi_db_name"))
target_bucket <- Sys.getenv("BOOTSTRAP_TARGET_BUCKET", Sys.getenv("s3_data_lake_bucket"))
target_root_prefix <- Sys.getenv("BOOTSTRAP_TARGET_ROOT_PREFIX", "")
source_bucket <- Sys.getenv("BOOTSTRAP_SOURCE_BUCKET", Sys.getenv("s3_data_lake_bucket"))
source_root_prefix <- Sys.getenv("BOOTSTRAP_SOURCE_ROOT_PREFIX", "")

if (identical(db_name, "")) {
  stop("Missing database name. Set BOOTSTRAP_DB_NAME or powerbi_db_name.")
}

if (identical(target_bucket, "")) {
  stop("Missing target S3 bucket. Set BOOTSTRAP_TARGET_BUCKET or s3_data_lake_bucket.")
}

if (identical(source_bucket, "")) {
  stop("Missing source S3 bucket. Set BOOTSTRAP_SOURCE_BUCKET or s3_data_lake_bucket.")
}

if (!identical(target_root_prefix, "") && !endsWith(target_root_prefix, "/")) {
  target_root_prefix <- paste0(target_root_prefix, "/")
}

if (!identical(source_root_prefix, "") && !endsWith(source_root_prefix, "/")) {
  source_root_prefix <- paste0(source_root_prefix, "/")
}

message("Loading AWS credentials and IAM role...")
secret_yaml_file_path <- Sys.getenv("secret_yaml_file_path")
if (identical(secret_yaml_file_path, "")) {
  stop("Missing secret_yaml_file_path environment variable.")
}

config <- yaml::read_yaml(secret_yaml_file_path, readLines.warn = FALSE)
iam_role <- config$scripts$aws$redshift$ondemand$iam_role_copy_s3

if (is.null(iam_role) || identical(iam_role, "")) {
  stop("Could not resolve IAM role at scripts.aws.redshift.ondemand.iam_role_copy_s3.")
}

Sys.setenv(
  AWS_ACCESS_KEY_ID = config$scripts$aws$access_key_id,
  AWS_SECRET_ACCESS_KEY = config$scripts$aws$secret_access_key,
  AWS_DEFAULT_REGION = config$scripts$aws$region_name
)

is_valid_identifier <- function(x) {
  grepl("^[A-Za-z_][A-Za-z0-9_]*$", x)
}

s3_prefix_has_objects <- function(bucket, prefix) {
  cmd <- c(
    "s3api", "list-objects-v2",
    "--bucket", bucket,
    "--prefix", prefix,
    "--max-items", "1",
    "--query", "length(Contents)",
    "--output", "text"
  )

  out <- system2("aws", cmd, stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) {
    stop(glue("AWS CLI failed for s3://{bucket}/{prefix}\n{paste(out, collapse = '\n')}"))
  }

  value <- trimws(paste(out, collapse = "\n"))
  !(value %in% c("", "0", "None", "null", "NULL"))
}

detect_table_mode_from_source_s3 <- function(bucket, prefix) {
  cmd <- c(
    "s3api", "list-objects-v2",
    "--bucket", bucket,
    "--prefix", prefix,
    "--max-items", "1000",
    "--query", "Contents[].Key",
    "--output", "text"
  )

  out <- system2("aws", cmd, stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) {
    stop(glue("AWS CLI failed while detecting mode for s3://{bucket}/{prefix}\n{paste(out, collapse = '\n')}"))
  }

  keys_blob <- paste(out, collapse = "\n")
  if (identical(trimws(keys_blob), "")) {
    return("overwrite")
  }

  has_year_month_partitions <-
    grepl("(^|/)year=[^/]+/month=[^/]+(/|$)", keys_blob, perl = TRUE)

  if (has_year_month_partitions) "append" else "overwrite"
}

resolve_append_date_col <- function(table_cols) {
  candidates <- c("report_date", "downloaded_at", "date", "created_at", "updated_at")
  match <- candidates[candidates %in% table_cols]
  if (length(match) == 0) return(NA_character_)
  match[[1]]
}

message(glue("Connecting to Redshift db '{db_name}'..."))
con <- get_redshift_connection(db_name = db_name)
on.exit(DBI::dbDisconnect(con), add = TRUE)

tables_sql <- glue("
  SELECT table_name
  FROM information_schema.tables
  WHERE table_schema = '{schema_name}'
    AND table_type = 'BASE TABLE'
  ORDER BY table_name
")

all_tables <- DBI::dbGetQuery(con, tables_sql)$table_name

if (length(all_tables) == 0) {
  message(glue("No tables found in schema '{schema_name}'. Nothing to do."))
  quit(save = 'no')
}

message(glue("Found {length(all_tables)} tables in schema '{schema_name}'."))

skipped_existing <- character()
processed_append <- character()
processed_overwrite <- character()
failed_tables <- character()

for (table_name in all_tables) {
  if (!is_valid_identifier(schema_name) || !is_valid_identifier(table_name)) {
    warning(glue("Skipping invalid identifier: {schema_name}.{table_name}"))
    failed_tables <- c(failed_tables, table_name)
    next
  }

  source_prefix <- paste0(source_root_prefix, schema_name, "/", table_name, "/")
  target_prefix <- paste0(target_root_prefix, schema_name, "/", table_name, "/")
  source_uri <- glue("s3://{source_bucket}/{source_prefix}")
  target_uri <- glue("s3://{target_bucket}/{target_prefix}")

  message("\n---------------------------------------------------")
  message(glue("Checking table: {schema_name}.{table_name}"))

  exists <- tryCatch(
    s3_prefix_has_objects(target_bucket, target_prefix),
    error = function(e) {
      warning(glue("Could not check target prefix for {table_name}: {e$message}"))
      NA
    }
  )

  if (isTRUE(exists)) {
    message(glue("SKIP: Target already has data at {target_uri}"))
    skipped_existing <- c(skipped_existing, table_name)
    next
  }

  mode <- tryCatch(
    detect_table_mode_from_source_s3(source_bucket, source_prefix),
    error = function(e) {
      warning(glue("Could not detect mode from source prefix {source_uri}: {e$message}"))
      "overwrite"
    }
  )
  message(glue("Detected mode from source layout: {mode} ({source_uri})"))

  query <- NULL
  if (mode == "append") {
    cols_sql <- glue("
      SELECT column_name
      FROM information_schema.columns
      WHERE table_schema = '{schema_name}'
        AND table_name = '{table_name}'
    ")
    table_cols <- DBI::dbGetQuery(con, cols_sql)$column_name
    date_col <- resolve_append_date_col(table_cols)

    if (is.na(date_col)) {
      warning(glue(
        "Mode detected as append for {table_name}, but no supported date column found. Falling back to overwrite mode."
      ))
      mode <- "overwrite"
    } else {
      query <- glue("
        UNLOAD ('
          SELECT *,
            TO_CHAR({date_col}, ''YYYY'') AS year,
            TO_CHAR({date_col}, ''MM'') AS month
          FROM {schema_name}.{table_name}
          WHERE {date_col} IS NOT NULL
            AND {date_col} < CURRENT_DATE
        ')
        TO '{target_uri}'
        IAM_ROLE '{iam_role}'
        FORMAT PARQUET
        PARTITION BY (year, month)
        ALLOWOVERWRITE;
      ")
      message(glue("Using append date column: {date_col}"))
    }
  }

  if (mode == "overwrite") {
    query <- glue("
      UNLOAD ('
        SELECT *
        FROM {schema_name}.{table_name}
      ')
      TO '{target_uri}'
      IAM_ROLE '{iam_role}'
      FORMAT PARQUET
      ALLOWOVERWRITE;
    ")
  }

  tryCatch(
    {
      DBI::dbExecute(con, query)
      if (mode == "append") {
        processed_append <- c(processed_append, table_name)
        message(glue("SUCCESS (append): unloaded historical data to {target_uri}"))
      } else {
        processed_overwrite <- c(processed_overwrite, table_name)
        message(glue("SUCCESS (overwrite): unloaded snapshot to {target_uri}"))
      }
    },
    error = function(e) {
      warning(glue("FAILED: {table_name} -> {e$message}"))
      failed_tables <- c(failed_tables, table_name)
    }
  )
}

message("\n===================================================")
message("Bootstrap summary")
message(glue("Append unloaded:    {length(processed_append)}"))
message(glue("Overwrite unloaded: {length(processed_overwrite)}"))
message(glue("Skipped existing:   {length(skipped_existing)}"))
message(glue("Failed:             {length(failed_tables)}"))

if (length(failed_tables) > 0) {
  message(glue("Failed tables: {paste(sort(unique(failed_tables)), collapse = ', ')}"))
}

message("Done.")
