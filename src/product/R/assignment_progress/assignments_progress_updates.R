library(tidyverse)
library(arrow)


source(paste0(Sys.getenv("path_common"), "R/run_mysql_query.R"))
source(paste0(Sys.getenv("path_common"), "R/read_parquet_from_s3.R"))
source("/src/product/R/assignment_progress/functions_assignment_progress.R")
source(paste0(Sys.getenv("path_common"), "R/write_parquet_to_s3.R"))


assignments <- run_mysql_query(
  connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"),
  db = "lecturio-live",
  query = paste0(
  "select a.id as assignment_id, ua.id as user_assignment_id, ua.user_id, a.institution_id,
  a.updated_at as assignment_updated_at, ua.updated_at as user_assignment_updated_at,
  if(ga.assignment_id is not null, 1, 0) as is_group_assignment
  from assignments as a
  join user_assignments as ua on ua.assignment_id = a.id
  left join (select distinct assignment_id from group_assignments) as ga on ga.assignment_id = a.id
  where (a.owner_user_id <> ua.user_id or a.owner_user_id is null)
  and a.institution_id not in (4974, 134)
  "))

# filter for updated_at within the last 5 days (also check when last run)
assignments_updated <- assignments %>%
  filter(user_assignment_updated_at > Sys.Date() - 7)
#filter(assignment_id %in% dupl_ids)

# --- Protective early exit ---
if (nrow(assignments_updated) == 0) {
  message("No assignments were updated in the last 7 days. Exiting successfully.")
  quit(save = "no", status = 0)
}
# ----------------------------------

# get assignment details and status for filtered assignments
# clean has_exam to a 0/1 flag upstream so it is consistent everywhere downstream
assignments_status_updated <- get_assignments(assignments_updated$user_assignment_id) %>%
  mutate(has_exam = ifelse(is.na(has_exam), 0, 1))

# get detailed progress for updated assignments
assignments_lecture_progress <- get_assignment_lecture_progress(assignments_status_updated)
assignments_course_progress <- get_assignment_course_progress(assignments_status_updated)
assignments_qbank_progress <- get_assignment_qbank_progress(assignments_status_updated)
assignments_lp_progress <- get_assignment_lp_progress(assignments_status_updated)


# join with existing data -----
# read existing progress data and join with updated progress

# Define your S3 state bucket path -- prev local csv ==> data ac
s3_data_lake_bucket <- Sys.getenv("s3_data_lake_bucket")

## lecture progress -----
# 1. Read existing state from S3
assignments_lecture_progress_existing <- tryCatch({
  read_parquet_from_s3(path = "powerbi/b2bu_assignments_lecture_progress", filename = "", s3_bucket = s3_data_lake_bucket, secrets_path = "aws", as_dataset = TRUE)
}, error = function(e) data.frame(user_id = integer(), assignment_id = integer(), content_id = character()))

lecture_user_assignment_ids <- assignments_lecture_progress %>%
  mutate(user_assignment_id = paste(user_id, assignment_id, sep = "-")) %>%
  pull(user_assignment_id) %>% unique()

assignments_lecture_progress2 <- assignments_lecture_progress_existing %>%
  mutate(content_id = as.character(content_id),
         user_assignment_id = paste(user_id, assignment_id, sep = "-")) %>%
  filter(!user_assignment_id %in% lecture_user_assignment_ids) %>%
  bind_rows(assignments_lecture_progress %>% mutate(content_id = as.character(content_id))) %>%
  select(-user_assignment_id)

# 2. Write updated state back to S3
# Write back to parent folder
write_parquet_to_s3(df = assignments_lecture_progress2, filename = "", path = "powerbi/b2bu_assignments_lecture_progress", partition_cols = NULL, s3_bucket = s3_data_lake_bucket, secrets_path = "aws", athena_db = NULL, existing_data_behavior = "delete_matching")
rm(assignments_lecture_progress_existing)
gc()

# test <- assignments_lecture_progress2 %>%
#   mutate(user_assignment_id = paste(user_id, assignment_id, sep = "-")) %>%
#   filter(duplicated(user_assignment_id) | duplicated(user_assignment_id, fromLast = TRUE))

## course progress -----
assignments_course_progress_existing <- tryCatch({
  read_parquet_from_s3(path = "powerbi/b2bu_assignments_course_progress", filename = "", s3_bucket = s3_data_lake_bucket, secrets_path = "aws", as_dataset = TRUE)
}, error = function(e) data.frame(user_id = integer(), assignment_id = integer(), content_id = character()))

course_user_assignment_ids <- assignments_course_progress %>%
  mutate(user_assignment_id = paste(user_id, assignment_id, sep = "-")) %>%
  pull(user_assignment_id) %>% unique()

assignments_course_progress2 <- assignments_course_progress_existing %>%
  mutate(content_id = as.character(content_id),
         user_assignment_id = paste(user_id, assignment_id, sep = "-")) %>%
  filter(!user_assignment_id %in% course_user_assignment_ids) %>%
  bind_rows(assignments_course_progress %>% mutate(content_id = as.character(content_id))) %>%
  select(-user_assignment_id)

# write new file
write_parquet_to_s3(df = assignments_course_progress2, filename = "", path = "powerbi/b2bu_assignments_course_progress", partition_cols = NULL, s3_bucket = s3_data_lake_bucket, secrets_path = "aws", athena_db = NULL, existing_data_behavior = "delete_matching")
rm(assignments_course_progress_existing)
gc()

## qbank progress -----
assignments_qbank_progress_existing <- tryCatch({
  read_parquet_from_s3(path = "powerbi/b2bu_assignments_qbank_progress", filename = "", s3_bucket = s3_data_lake_bucket, secrets_path = "aws", as_dataset = TRUE)
}, error = function(e) data.frame(user_id = integer(), assignment_id = integer(), content_id = character()))

qbank_user_assignment_ids <- assignments_qbank_progress %>%
  mutate(user_assignment_id = paste(user_id, assignment_id, sep = "-")) %>%
  pull(user_assignment_id) %>% unique()

assignments_qbank_progress2 <- assignments_qbank_progress_existing %>%
  mutate(content_id = as.character(content_id),
         user_assignment_id = paste(user_id, assignment_id, sep = "-")) %>%
  filter(!user_assignment_id %in% qbank_user_assignment_ids) %>%
  bind_rows(assignments_qbank_progress %>% mutate(content_id = as.character(content_id))) %>%
  select(-user_assignment_id)

# write new file
write_parquet_to_s3(df = assignments_qbank_progress2, filename = "", path = "powerbi/b2bu_assignments_qbank_progress", partition_cols = NULL, s3_bucket = s3_data_lake_bucket, secrets_path = "aws", athena_db = NULL, existing_data_behavior = "delete_matching")
rm(assignments_qbank_progress_existing)
gc()

## lp progress -----
assignments_lp_progress_existing <- tryCatch({
  read_parquet_from_s3(path = "powerbi/b2bu_assignments_lp_progress", filename = "", s3_bucket = s3_data_lake_bucket, secrets_path = "aws", as_dataset = TRUE)
}, error = function(e) data.frame(user_id = integer(), assignment_id = integer(), content_id = character()))

lp_user_assignment_ids <- assignments_lp_progress %>%
  mutate(user_assignment_id = paste(user_id, assignment_id, sep = "-")) %>%
  pull(user_assignment_id) %>% unique()

assignments_lp_progress2 <- assignments_lp_progress_existing %>%
  mutate(content_id = as.character(content_id),
         user_assignment_id = paste(user_id, assignment_id, sep = "-")) %>%
  filter(!user_assignment_id %in% lp_user_assignment_ids) %>%
  bind_rows(assignments_lp_progress %>% mutate(content_id = as.character(content_id))) %>%
  select(-user_assignment_id)

# write new file
write_parquet_to_s3(df = assignments_lp_progress2, filename = "", path = "powerbi/b2bu_assignments_lp_progress", partition_cols = NULL, s3_bucket = s3_data_lake_bucket, secrets_path = "aws", athena_db = NULL, existing_data_behavior = "delete_matching")
rm(assignments_lp_progress_existing)
gc()

# add institution_id to assignments and join into one file per institution and write to S3
# -------------------------------------------------------------------------
# GLOBAL VECTORIZED PROCESSING (Replaces the for-loop)
# -------------------------------------------------------------------------

# 1. Group and summarize the updated statuses across ALL institutions at once
all_assignments_status_updated <- assignments_status_updated %>%
  group_by(across(-content_id)) %>%
  summarise(content_id = paste0(unique(content_id), collapse = ", "),
            .groups = "drop") %>%
  # Bring institution_id (and is_group_assignment) back into the dataframe
  inner_join(assignments, by = c("assignment_id", "user_id", "user_assignment_id"))

# 2. Setup S3 bucket STRINGS (Strictly bucket names ONLY)
prod_ci_bucket <- Sys.getenv("prod_ci_bucket")
tenants_usage_bucket <- Sys.getenv("tenants_usage_bucket")

# 3. Read existing statuses from the S3 partitioned dataset (PROD AC - read_data_sources)
all_assignments_status_existing <- tryCatch({
  read_parquet_from_s3(
    path = "assignments_status",
    s3_bucket = prod_ci_bucket,
    secrets_path = "aws_lecturio_prod$read_data_sources",
    as_dataset = TRUE
  )
}, error = function(e) {
  data.frame(user_assignment_id = integer())
})

# 4. Merge existing data with new data
if (nrow(all_assignments_status_existing) == 0) {
  all_inst_assignments_status <- all_assignments_status_updated
} else {
  ids_to_check <- setdiff(all_assignments_status_existing$user_assignment_id,
                          all_assignments_status_updated$user_assignment_id)

  all_assignments_status_current <- get_current_assignment_status(ids_to_check) %>%
    rename(progress_current = progress)

  all_inst_assignments_status <- all_assignments_status_existing %>%
    filter(!user_assignment_id %in% all_assignments_status_updated$user_assignment_id) %>%
    left_join(all_assignments_status_current, by = "user_assignment_id") %>%
    mutate(
      status = if_else(is.na(status_current), status, status_current),
      progress = if("progress" %in% names(.)) coalesce(progress_current, progress) else progress_current
    ) %>%
    select(-status_current, -progress_current) %>%
    bind_rows(all_assignments_status_updated)
}

# 5. Write Status to Main S3 Bucket (PROD AC - write_to_s3)
write_parquet_to_s3(
  df = all_inst_assignments_status,
  filename = "assignments_status",
  path = "",  
  partition_cols = "institution_id",
  s3_bucket = prod_ci_bucket,
  secrets_path = "aws_lecturio_prod$write_to_s3",
  athena_db = NULL,
  existing_data_behavior = "delete_matching"
)

athena_db <- Sys.getenv("tenants_usage_athena_db")
athena_staging_dir <- paste0(Sys.getenv("tenants_usage_s3_staging_dir"), athena_db, "/")

# 6. Write Status to Athena Bucket (PROD AC - tenants_usage_athena)
write_parquet_to_s3(
  df = all_inst_assignments_status %>% mutate(tenant_id = institution_id),
  filename = "assignments_status",
  path = "v1/metrics", 
  partition_cols = "tenant_id",
  s3_bucket = tenants_usage_bucket,
  secrets_path = "aws_lecturio_prod$write_to_s3",
  athena_secrets_path = "aws_lecturio_prod$tenants_usage_athena",
  athena_s3_staging_dir = athena_staging_dir,
  athena_workgroup = Sys.getenv("tenants_usage_athena_workgroup"),
  athena_db = athena_db,
  existing_data_behavior = "delete_matching"
)

# 7. Write native partitions for the detailed progress files
for (type in c("lecture", "course", "qbank", "lp")) {

  df_to_write <- get(paste0("assignments_", type, "_progress2")) %>%
    inner_join(assignments, by = c("assignment_id", "user_id"))

  table_name <- paste0("assignments_", type, "_progress")

  # Write to main S3 bucket (PROD AC - write_to_s3)
  write_parquet_to_s3(
    df = df_to_write,
    filename = table_name,
    path = "", 
    partition_cols = "institution_id",
    s3_bucket = prod_ci_bucket,
    secrets_path = "aws_lecturio_prod$write_to_s3",
    athena_db = NULL,
    existing_data_behavior = "delete_matching"
  )

  # Write to Athena bucket (PROD AC - tenants_usage_athena)
  write_parquet_to_s3(
    df = df_to_write %>% mutate(tenant_id = institution_id),
    filename = table_name, 
    path = "v1/metrics",
    partition_cols = "tenant_id",
    s3_bucket = tenants_usage_bucket,
    secrets_path = "aws_lecturio_prod$write_to_s3",
    athena_secrets_path = "aws_lecturio_prod$tenants_usage_athena",
    athena_s3_staging_dir = athena_staging_dir,
    athena_workgroup = Sys.getenv("tenants_usage_athena_workgroup"),
    athena_db = athena_db,
    existing_data_behavior = "delete_matching"
  )
}
