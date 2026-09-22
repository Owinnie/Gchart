# Resolve Athena region and query-result location for noctua.
#
# activity_dag.qbank_attempts_b2u failed with:
#   InvalidRequestException (HTTP 400). Unable to verify/create output bucket katrin-test
#
# katrin-test is the intended results bucket for s3_data_lake.reader.dev.
# That IAM policy only allows object writes under:
#   s3://katrin-test/athena-results/
# and only against Athena in eu-central-1 / workgroup primary.
#
# The old helper did paste0(Sys.getenv("s3_staging_dir"), db, "/").
# If s3_staging_dir was s3://katrin-test/ that became
# s3://katrin-test/powerbi_old/, which is outside the IAM prefix.
# Athena then fails while verifying the bucket.
#
# Region, first non-empty:
#   AWS_REGION, AWS_DEFAULT_REGION, secrets.yaml scripts.aws.region_name, eu-central-1
# When the results bucket is katrin-test, region is forced to eu-central-1.

ATHENA_REGION_DEFAULT <- "eu-central-1"
KATRIN_RESULTS_BUCKET <- "katrin-test"
KATRIN_RESULTS_PREFIX <- "athena-results"
KATRIN_RESULTS_URI <- "s3://katrin-test/athena-results/"
CUBE_RESULTS_URI <- "s3://cube-athena-query-results-dev/"

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

extract_s3_key <- function(uri) {
  if (is.null(uri) || !nzchar(uri)) {
    return("")
  }
  path <- sub("^s3://", "", trimws(uri), ignore.case = TRUE)
  if (!grepl("/", path)) {
    return("")
  }
  sub("^[^/]+/", "", path)
}

normalize_s3_uri <- function(value, db = NULL) {
  if (is.null(value) || !nzchar(trimws(value))) {
    return("")
  }
  uri <- trimws(value)
  if (!grepl("^s3://", uri, ignore.case = TRUE)) {
    uri <- paste0("s3://", uri)
  }
  uri <- sub("^s3://", "s3://", uri, ignore.case = TRUE)
  if (!grepl("/$", uri)) {
    uri <- paste0(uri, "/")
  }
  if (!is.null(db) && nzchar(db)) {
    db_suffix <- paste0(db, "/")
    if (!grepl(paste0(db_suffix, "$"), uri, fixed = TRUE)) {
      uri <- paste0(uri, db_suffix)
    }
  }
  uri
}

# IAM for katrin-test only allows athena-results/. Rewrite bucket-root or
# other prefixes (including the old helper's /{db}/) onto that prefix.
ensure_allowed_athena_prefix <- function(uri, db = NULL) {
  if (is.null(uri) || !nzchar(trimws(uri))) {
    return("")
  }
  bucket <- tolower(extract_s3_bucket(uri))
  if (!identical(bucket, KATRIN_RESULTS_BUCKET)) {
    return(normalize_s3_uri(uri, db = db))
  }

  key <- extract_s3_key(uri)
  has_allowed_prefix <- grepl(
    paste0("^", KATRIN_RESULTS_PREFIX, "(/|$)"),
    key
  )
  if (!isTRUE(has_allowed_prefix)) {
    message(
      "Rewriting Athena output ", trimws(uri),
      " to IAM-allowed prefix ", KATRIN_RESULTS_URI
    )
    uri <- KATRIN_RESULTS_URI
  }
  normalize_s3_uri(uri, db = db)
}

resolve_athena_region <- function(secret_region = NULL, env = NULL, staging_uri = NULL) {
  secret_value <- ""
  if (!is.null(secret_region) && !is.na(secret_region) && nzchar(as.character(secret_region))) {
    secret_value <- trimws(as.character(secret_region))
  }
  candidates <- c(
    get_env_value("AWS_REGION", env),
    get_env_value("AWS_DEFAULT_REGION", env),
    secret_value,
    ATHENA_REGION_DEFAULT
  )
  candidates <- candidates[nzchar(candidates)]
  region <- candidates[[1]]

  bucket <- tolower(extract_s3_bucket(staging_uri))
  if (identical(bucket, KATRIN_RESULTS_BUCKET) && !identical(region, ATHENA_REGION_DEFAULT)) {
    message(
      "Forcing Athena region ", ATHENA_REGION_DEFAULT,
      " because katrin-test / workgroup primary live there (was ", region, ")"
    )
    return(ATHENA_REGION_DEFAULT)
  }
  region
}

staging_candidates <- function(explicit = NULL, env = NULL) {
  explicit_value <- if (is.null(explicit)) "" else trimws(as.character(explicit))
  c(
    explicit_value,
    get_env_value("AWS_ATHENA_S3_STAGING_DIR", env),
    get_env_value("s3_staging_dir", env),
    get_env_value("athena_s3_output_bucket", env),
    KATRIN_RESULTS_URI,
    CUBE_RESULTS_URI
  )
}

resolve_athena_s3_staging_dir <- function(db, explicit = NULL, env = NULL) {
  for (raw in staging_candidates(explicit = explicit, env = env)) {
    if (!nzchar(raw)) {
      next
    }
    uri <- ensure_allowed_athena_prefix(raw, db = db)
    if (nzchar(uri)) {
      return(uri)
    }
  }
  stop(
    "No Athena query-results location configured. ",
    "Set s3_staging_dir=s3://katrin-test/athena-results/ in .Renviron, ",
    "then rebuild r-code:latest.",
    call. = FALSE
  )
}
