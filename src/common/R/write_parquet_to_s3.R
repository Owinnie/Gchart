write_parquet_to_s3 <- function(df,
                                filename,
                                path,
                                overwrite = TRUE,
                                existing_data_behavior = "overwrite",
                                partition_cols = NULL,
                                max_partitions = 1000,
                                s3_bucket = Sys.getenv("s3_data_lake_bucket"),
                                secrets_path = "aws",
                                athena_secrets_path = "aws",
                                athena_s3_staging_dir = NULL,
                                athena_workgroup = NULL,
                                athena_db = Sys.getenv("athena_db")) {

  # existing_data_behavior: must be either "overwrite" --> this overwrites existing FILES with the same name only, partitions are untouched
  # or "delete_matching" --> this deletes existing PARTITIONS with all files in it if written out again, leaves other partitions unchanged

  message("Starting automated S3 upload for: ", filename)

  tryCatch({

    # 1. LOAD DEPENDENCIES
    library(arrow, quietly = TRUE)
    library(yaml, quietly = TRUE)
    library(dplyr, quietly = TRUE)

    # 2. THE SCHEMA FIXER: Standardize data types for Parquet
    df <- df %>%
      mutate(
        across(matches("_at$|date$|time$"),
               ~ if (is.character(.x)) lubridate::as_datetime(.x) else .x)
      )

    # 3. INPUT VALIDATION
    if (!is.null(partition_cols)) {
      if (length(partition_cols) == 0) {
        stop("partition_cols was provided but is empty. Use NULL for no partitioning.")
      }
      missing_cols <- setdiff(partition_cols, names(df))
      if (length(missing_cols) > 0) {
        stop("partition_cols not in df: ", paste(missing_cols, collapse = ", "))
      }
      if (!is.null(athena_db) && nchar(athena_db) > 0 && !nzchar(filename)) {
        stop("filename must be set for Athena MSCK REPAIR on partitioned datasets.")
      }
    }

    # Validate max_partitions
    if (!is.numeric(max_partitions) || max_partitions < 1) {
      stop("max_partitions must be a positive integer.")
    }

    if (nrow(df) == 0) {
      message("No rows to upload for: ", filename, " — skipping S3 write.")
      return(invisible(NULL))
    }

    # 4. SETUP S3 CONNECTION
    config <- yaml::read_yaml(Sys.getenv("secret_yaml_file_path"), readLines.warn = FALSE)
    source(paste0(Sys.getenv("path_common"), "R/aws_utils.R"))
    creds <- resolve_aws_secrets(config, secrets_path)

    s3_fs_args <- list(
      access_key = creds$access_key_id,
      secret_key = creds$secret_access_key,
      region = creds$region_name,
      scheme = "https"
    )

    if (!is.null(creds$session_token) && nchar(creds$session_token) > 0) {
      s3_fs_args$session_token <- creds$session_token
    }
    s3 <- do.call(arrow::S3FileSystem$create, s3_fs_args)

    # 5. DETERMINE PATHS, LABELS & DYNAMIC TEMPLATES
    path_segments <- c(path, filename)
    path_segments <- path_segments[nzchar(path_segments)]
    final_path <- paste0(s3_bucket, "/", paste(path_segments, collapse = "/"))
    partition_label <- if (is.null(partition_cols)) "none" else paste(partition_cols, collapse = ", ")

    # Dynamically assign the basename template based on the overwrite flag
    b_template <- if (isTRUE(overwrite)) {
      "data_{i}.parquet"
    } else {
      paste0("data_", format(Sys.time(), "%Y%m%d_%H%M%S"), "_{i}.parquet")
    }

    # 6. EXECUTE WRITE
    existing_data_behavior <- match.arg(existing_data_behavior, c("overwrite", "delete_matching"))

    if (is.null(partition_cols)) {
      arrow::write_dataset(
        dataset = df,
        path = s3$path(final_path),
        format = "parquet",
        partitioning = NULL,
        basename_template = b_template,
        compression = "snappy",
        existing_data_behavior = existing_data_behavior
      )
      message("Dataset uploaded (no partitioning) to ", final_path)
    } else {
      # partitioned write; batched when #partitions > max_partitions

      # a) Identify all unique combinations of partition columns
      unique_partitions <- df %>%
        select(all_of(partition_cols)) %>%
        distinct()

      # b) Assign a chunk ID to group them (e.g., batches of 1000)
      chunk_size <- max_partitions
      unique_partitions$chunk_id <- rep(
        seq_len(ceiling(nrow(unique_partitions) / chunk_size)),
        each = chunk_size,
        length.out = nrow(unique_partitions)
      )

      # c) Loop through each batch and write to S3
      for (current_chunk in unique(unique_partitions$chunk_id)) {
        batch_keys <- unique_partitions %>%
          filter(chunk_id == current_chunk) %>%
          select(-chunk_id)

        df_batch <- df %>%
          semi_join(batch_keys, by = partition_cols)

        arrow::write_dataset(
          dataset = df_batch,
          path = s3$path(final_path),
          format = "parquet",
          partitioning = partition_cols,
          basename_template = b_template,
          compression = "snappy",
          existing_data_behavior = existing_data_behavior
        )
      }

      message("Dataset partitioned by [", partition_label, "] uploaded to ", final_path)

      # Handle MSCK REPAIR without failing the whole Airflow task
      if (!is.null(athena_db) && nchar(athena_db) > 0) {
        tryCatch({
          source(paste0(Sys.getenv("path_common"), "R/run_athena_query.R"))

          # Database context is set via schema_name in run_athena_query (db = athena_db).
          # Do not qualify as db.table — MSCK fails with the same parser error as in the UI.
          repair_sql <- paste0("MSCK REPAIR TABLE ", filename)
          message("Running Athena partition repair: ", repair_sql)
          effective_staging_dir <- if (is.null(athena_s3_staging_dir)) {
            paste0(Sys.getenv("s3_staging_dir"), athena_db, "/")
          } else {
            athena_s3_staging_dir
          }
          effective_workgroup <- if (is.null(athena_workgroup) || !nzchar(athena_workgroup)) {
            Sys.getenv("athena_workgroup", unset = "primary")
          } else {
            athena_workgroup
          }
          repair_result <- run_athena_query(
            db = athena_db,
            query = repair_sql,
            secrets_path = athena_secrets_path,
            s3_staging_dir = effective_staging_dir,
            workgroup = effective_workgroup
          )
          # run_athena_query() returns NULL only when the connection could not
          # be established. A successful DDL/utility query (like MSCK REPAIR)
          # now returns invisible(TRUE), so a NULL here really does mean the
          # connection failed.
          if (is.null(repair_result)) {
            warning("S3 Upload succeeded, but Athena MSCK REPAIR failed: could not connect to Athena (", athena_db, ")")
          }

        }, error = function(repair_err) {
          # Only throw a warning, don't break the Airflow task
          warning("S3 Upload succeeded, but Athena MSCK REPAIR failed: ", repair_err$message)
        })
      } else {
        message("Skipping Athena MSCK REPAIR: athena_db is not set.")
      }
    }

    invisible(final_path)

  }, error = function(e) {
    stop("Automated S3 Upload failed for ", filename, ":\n", e$message, call. = FALSE)
  })
}
