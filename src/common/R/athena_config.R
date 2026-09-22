# Resolve Athena region and query-result location for noctua.
#
# activity_dag.qbank_attempts_b2u failed with:
#   InvalidRequestException (HTTP 400). Unable to verify/create output bucket katrin-test
#
# Setting AWS_REGION in .Renviron is not enough on its own:
# run_athena_query used to take region_name from secrets.yaml and
# s3_staging_dir from Sys.getenv("s3_staging_dir"), which still pointed
# at the leftover personal bucket "katrin-test".
#
# Region, first non-empty:
#   AWS_REGION, AWS_DEFAULT_REGION, secrets.yaml scripts.aws.region_name, eu-central-1
#
# Query-results URI, first usable:
#   explicit argument, AWS_ATHENA_S3_STAGING_DIR, s3_staging_dir,
#   athena_s3_output_bucket, s3_data_lake_bucket, s3_to_redshift_bucket
# The leftover bucket "katrin-test" is never used.

UNUSABLE_ATHENA_OUTPUT_BUCKETS <- c("katrin-test")

get_env_value <- function(name, env = NULL) {
  if (is.null(env)) {
    value <- Sys.getenv(name, unset = "")
  } else {
    value <- env[[name]]
    if (is.null(value)) {
      value <- ""
    }
  }
  if (length(value) == 0 || is.na(value[[1]])) {
    return("")
  }
  trimws(as.character(value[[1]]))
}

extract_s3_bucket <- function(uri) {
  if (is.null(uri) || !nzchar(uri)) {
    return("")
  }
  path <- sub("^s3://", "", trimws(uri), ignore.case = TRUE)
  sub("/.*$", "", path)
}

is_unusable_athena_output_bucket <- function(bucket) {
  if (is.null(bucket) || !nzchar(bucket)) {
    return(TRUE)
  }
  tolower(bucket) %in% UNUSABLE_ATHENA_OUTPUT_BUCKETS
}

s3_uri_has_key_prefix <- function(uri) {
  if (is.null(uri) || !nzchar(uri)) {
    return(FALSE)
  }
  path <- sub("^s3://", "", trimws(uri), ignore.case = TRUE)
  grepl("/", path)
}

normalize_s3_uri <- function(value, db = NULL, query_results_prefix = FALSE) {
  if (is.null(value) || !nzchar(trimws(value))) {
    return("")
  }
  uri <- trimws(value)
  if (!grepl("^s3://", uri, ignore.case = TRUE)) {
    uri <- paste0("s3://", uri)
  }
  # Canonical scheme casing so noctua always gets s3://
  uri <- sub("^s3://", "s3://", uri, ignore.case = TRUE)
  if (!grepl("/$", uri)) {
    uri <- paste0(uri, "/")
  }
  if (isTRUE(query_results_prefix) && !grepl("/athena-query-results/?$", uri)) {
    uri <- paste0(uri, "athena-query-results/")
  }
  if (!is.null(db) && nzchar(db)) {
    db_suffix <- paste0(db, "/")
    if (!grepl(paste0(db_suffix, "$"), uri, fixed = FALSE)) {
      uri <- paste0(uri, db_suffix)
    }
  }
  uri
}

resolve_athena_region <- function(secret_region = NULL, env = NULL) {
  secret_value <- ""
  if (!is.null(secret_region) && !is.na(secret_region) && nzchar(as.character(secret_region))) {
    secret_value <- trimws(as.character(secret_region))
  }
  candidates <- c(
    get_env_value("AWS_REGION", env),
    get_env_value("AWS_DEFAULT_REGION", env),
    secret_value,
    "eu-central-1"
  )
  candidates <- candidates[nzchar(candidates)]
  candidates[[1]]
}

staging_candidates <- function(explicit = NULL, env = NULL) {
  explicit_value <- if (is.null(explicit)) "" else trimws(as.character(explicit))
  list(
    list(value = explicit_value, kind = "staging"),
    list(value = get_env_value("AWS_ATHENA_S3_STAGING_DIR", env), kind = "staging"),
    list(value = get_env_value("s3_staging_dir", env), kind = "staging"),
    list(value = get_env_value("athena_s3_output_bucket", env), kind = "data_bucket"),
    list(value = get_env_value("s3_data_lake_bucket", env), kind = "data_bucket"),
    list(value = get_env_value("s3_to_redshift_bucket", env), kind = "data_bucket")
  )
}

resolve_athena_s3_staging_dir <- function(db, explicit = NULL, env = NULL) {
  skipped <- character()
  candidates <- staging_candidates(explicit = explicit, env = env)

  for (candidate in candidates) {
    raw <- candidate$value
    if (!nzchar(raw)) {
      next
    }
    bucket <- extract_s3_bucket(raw)
    if (is_unusable_athena_output_bucket(bucket)) {
      skipped <- c(skipped, bucket)
      next
    }

    use_query_prefix <- identical(candidate$kind, "data_bucket") && !s3_uri_has_key_prefix(raw)
    uri <- normalize_s3_uri(raw, db = db, query_results_prefix = use_query_prefix)
    if (nzchar(uri) && !is_unusable_athena_output_bucket(extract_s3_bucket(uri))) {
      if (length(skipped) > 0) {
        message(
          "Skipping Athena output bucket(s) ",
          paste(unique(skipped), collapse = ", "),
          " (known-unusable leftover). Using ", uri
        )
      }
      return(uri)
    }
  }

  skipped_note <- ""
  if (length(skipped) > 0) {
    skipped_note <- paste0(
      " Ignored leftover bucket(s): ",
      paste(unique(skipped), collapse = ", "),
      "."
    )
  }
  stop(
    "No usable Athena query-results bucket configured.",
    skipped_note,
    " Set s3_staging_dir or s3_data_lake_bucket in .Renviron to an existing S3 ",
    "bucket in the Athena region, then rebuild r-code:latest.",
    call. = FALSE
  )
}
