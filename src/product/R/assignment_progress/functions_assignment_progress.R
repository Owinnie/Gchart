get_assignments <- function(user_assignment_ids) {

  if (length(user_assignment_ids) == 0) {
    return(data.frame())
  }

  # Split the IDs into chunks of 5000 to avoid MySQL 'max_allowed_packet' errors
  chunk_size <- 5000
  chunks <- split(user_assignment_ids, ceiling(seq_along(user_assignment_ids) / chunk_size))

  # Loop through chunks, query the database, and store results in a list
  results_list <- lapply(chunks, function(chunk_ids) {
    run_mysql_query(
      connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
      query = paste0(
      "select a.id as assignment_id,
      a.owner_user_id,
      ua.id as user_assignment_id,
      ua.user_id,
      ua.title as content,
      ua.exam_state as has_exam,
      ua.is_mandatory as mandatory,
      ua.created_at as assignment_assigned_at,
      ua.due_date,
      ua.on_track_until,
      ua.updated_at,
      ua.completed_at,
      ua.progress,
      a.created_at as assignment_created_at,
      if(ua.progress = 100 and (exam_state is null or exam_state = '3'), 'completed',
        if(ua.due_date is null,
          if(ua.progress = 0, 'not started', 'in progress'),
          if(ua.on_track_until < now(),
            if(ua.due_date < now(), 'overdue', 'not on track'),
            if(ua.progress = 0, 'not started', 'in progress')
            )
          )
        ) as status,
        -- content type
        case when uac.id is not null then 'course'
        when uaqt.id is not null then 'qbank_test'
        when uacc.id is not null then 'catalog_category'
        when ual.id is not null then 'lecture'
        when uai.id is not null then 'instruction'
        when uass.id is not null then 'simulation_scenario'
        when uatr.id is not null then 'topic_review'
        else 'unknown' end as content_type,
        -- content_id
        case when uac.id is not null then uac.course_id
        when uaqt.id is not null then uaqt.test_id
        when uacc.id is not null then uacc.catalog_category_id
        when ual.id is not null then ual.lecture_id
        when uai.id is not null then uai.instruction_id
        when uass.id is not null then uass.scenario_id
        when uatr.id is not null then uatr.topic_review_id
        else null end as content_id
      from assignments as a
      join user_assignments as ua on ua.assignment_id = a.id
      -- join with individual assignment types
      left join user_assigned_courses as uac on uac.assignment_id = a.id
      left join user_assigned_qbank_tests as uaqt on uaqt.assignment_id = a.id
      left join user_assigned_catalog_categories as uacc on uacc.assignment_id = a.id
      left join user_assigned_lectures as ual on ual.assignment_id = a.id
      left join user_assigned_instructions as uai on uai.assignment_id = a.id
      left join user_assigned_simulation_scenarios as uass on uass.assignment_id = a.id
      left join user_assigned_topic_reviews as uatr on uatr.assignment_id = a.id
      where ua.id in (", paste0(chunk_ids, collapse = ", "), ")
      ;"))
  })

  # Combine all chunked results into a single dataframe
  dplyr::bind_rows(results_list)
}

# get current assignment status (Updated to handle large vectors via chunking)
get_current_assignment_status <- function(user_assignment_ids) {
  # If the list is empty, return an empty dataframe immediately
  if(length(user_assignment_ids) == 0) {
    return(data.frame(user_assignment_id = integer(), progress = numeric(), status_current = character()))
  }
  # Split the IDs into chunks of 10,000 to avoid MySQL 'max_allowed_packet' errors
  chunk_size <- 10000
  chunks <- split(user_assignment_ids, ceiling(seq_along(user_assignment_ids) / chunk_size))
  # Loop through chunks, query the database, and store results in a list
  results_list <- lapply(chunks, function(chunk_ids) {
    run_mysql_query(
      connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
      query = paste0(
      "select
      ua.id as user_assignment_id,
      ua.progress,
      if(ua.progress = 100 and (exam_state is null or exam_state = '3'), 'completed',
        if(ua.due_date is null,
          if(ua.progress = 0, 'not started', 'in progress'),
          if(ua.on_track_until < now(),
            if(ua.due_date < now(), 'overdue', 'not on track'),
            if(ua.progress = 0, 'not started', 'in progress')
            )
          )
        ) as status_current
      from user_assignments as ua
      where ua.id in (", paste0(chunk_ids, collapse = ", "), ")
      ;"
    ))
  })
  # Combine all chunked results into a single dataframe
  bind_rows(results_list)
}

# get lecture activity
get_lecture_results <- function(user_lectures){

  user_ids <- na.omit(unique(user_lectures$user_id))
  lecture_ids <- na.omit(unique(user_lectures$lecture_id))

  user_lecture_ids <- user_lectures %>%
    mutate(user_lecture_id = paste(user_id, lecture_id, sep = "-")) %>%
    pull(user_lecture_id) %>%
    unique()

  # only started lectures are in users_visited_lectures
  lecture_activity <- run_mysql_query(
    connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
    query = paste0(
    "select ul.user_id,
  ul.lecture_id,
  if(percentage_watched > 0, 1, 0) as started,
  if(completely_watched_date is null, 0, 1) as finished
  from users_visited_lectures as ul
  where lecture_id in (", paste0(lecture_ids, collapse = ", "), ")
  and user_id in (", paste0(user_ids, collapse = ", "), ")
  ;"))

  lecture_activity_f <- lecture_activity %>%
    mutate(user_lecture_id = paste(user_id, lecture_id, sep = "-")) %>%
    filter(user_lecture_id %in% user_lecture_ids)

  # get question answers for lectures
  questions <- run_mysql_query(
    connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
    query = paste0(
    "select qn.lecture_id, count(q.id) as n_questions -- q.id as question_id
  from questionnaires as qn
  join questions as q on q.questionnaire_id = qn.id
  where qn.lecture_id in (", paste0(lecture_ids, collapse = ", "), ")
  and qn.is_published = 1 and q.show_in_lecture = 1
  group by qn.lecture_id
  ;"))

  # n_questions_lecture <- questions %>%
  #   group_by(lecture_id) %>%
  #   summarise(n_questions = n())

  #question_ids <- na.omit(unique(questions$question_id))

  # get answers
  question_activity <- run_mysql_query(
    connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
    query = paste0(
    "select user_id, lecture_id, sum(is_correct) as n_correct, count(question_id) as n_total
  from users_answered_questions uaq
  join questions as q on q.id = uaq.question_id
  join questionnaires as qn on qn.id = q.questionnaire_id
  where uaq.user_id in (", paste0(user_ids, collapse = ", "), ")
  and qn.lecture_id in (", paste0(lecture_ids, collapse = ", "), ")
  group by user_id, lecture_id
  ;"))

  question_activity_f <- question_activity %>%
    mutate(user_lecture_id = paste(user_id, lecture_id, sep = "-")) %>%
    filter(user_lecture_id %in% user_lecture_ids)

  # finalise data frame
  # n_lectures, n_started_lectures, perc_started_lectures, n_finished_lectures, perc_finished_lectures
  # n_questions, n_answered_questions, perc_answered_questions, n_correct, perc_correct, n_incorrect, perc_incorrect
  user_lecture_activity <- user_lectures %>%
    unique() %>%
    left_join(lecture_activity_f, by = c("user_id", "lecture_id")) %>%
    left_join(questions, by = c("lecture_id" = "lecture_id")) %>%
    left_join(question_activity_f, by = c("user_id", "lecture_id")) %>%
    mutate(n_lectures = 1,
           n_started_lectures = ifelse(is.na(started) | started == 0, 0, 1),
           n_finished_lectures = ifelse(is.na(finished) | finished == 0, 0, 1),
           n_questions = ifelse(is.na(n_questions), 0, n_questions),
           n_answered_questions = ifelse(n_questions == 0, NA, ifelse(is.na(n_total), 0, n_total)),
           n_correct = ifelse(n_questions == 0, NA, ifelse(is.na(n_correct), 0, n_correct)),
           n_incorrect = ifelse(n_questions == 0, NA, n_answered_questions - n_correct),
    ) %>%
    select(user_id, lecture_id, n_lectures, n_started_lectures, n_finished_lectures,
           n_questions, n_answered_questions, n_correct, n_incorrect)

}


get_exam_results <- function(user_exams, content_type) {

  user_ids <- na.omit(unique(user_exams$user_id))
  content_ids <- na.omit(unique(user_exams$content_id))

  user_content_ids <- user_exams %>%
    mutate(user_content_id = paste(user_id, content_id, sep = "-")) %>%
    pull(user_content_id) %>%
    unique()

  # get exam activity
  exam_activity <- run_mysql_query(
    connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
    query = paste0(
    "select user_id, content_id, has_passed, first_success_date,
    created_at, updated_at
  from exam_results
  where user_id in (", paste0(user_ids, collapse = ", "), ")
  and content_type = '", content_type, "'
  and content_id in (", paste0(content_ids, collapse = ", "), ")
  ;"))

  exam_activity_f <- exam_activity %>%
    mutate(exam_passed_failed_date = if_else(has_passed == 1,
                                             if_else(is.na(first_success_date),
                                                     if_else(is.na(updated_at), created_at, updated_at),
                                                     first_success_date),
                                             if_else(is.na(updated_at), created_at, updated_at)),
           # convert to UTC
           exam_passed_failed_date_CET = lubridate::force_tz(exam_passed_failed_date, tz = "Europe/Paris"),
           exam_passed_failed_date_UTC = lubridate::with_tz(exam_passed_failed_date_CET, tzone = "UTC")
    ) %>%
    mutate(user_content_id = paste(user_id, content_id, sep = "-")) %>%
    filter(user_content_id %in% user_content_ids) %>%
    select(user_id, content_id, has_passed, exam_passed_failed_date_UTC)

}


get_qbank_results <- function(users_tests) {

  test_ids <- na.omit(unique(users_tests$test_id))
  user_ids <- na.omit(unique(users_tests$user_id))

  tests <- run_mysql_query(
    connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
    query = paste0(
    "select tq.test_id,
      ifnull(is_randomized, 0) as is_randomized,
      if(isnull(rand_tests.n_questions) or rand_tests.n_questions = 0, count(distinct tq.question_id), rand_tests.n_questions) as n_questions,
      -- ifnull(rand_tests.n_questions, count(distinct tq.question_id)) as n_questions,
      if(is_randomized is null, sum(q.points), sum(q.points)/rand_tests.n_questions) as n_total_points
  from LecturioQbank.tests_questions as tq
  join LecturioQbank.questions as q on q.id = tq.question_id
  left join (
        select rt.test_id, ts.value as n_questions, 1 as is_randomized
        from LecturioQbank.test_settings as rt
        join LecturioQbank.test_settings as ts on ts.test_id = rt.test_id
            and ts.name = 'attempt_questions_limit'
        where rt.test_id in (", paste0(test_ids, collapse = ", "), ")
        and (rt.name = 'attempt_questions_randomized' and rt.value = 1)
  ) as rand_tests on rand_tests.test_id = tq.test_id
  where tq.test_id in (", paste0(test_ids, collapse = ", "), ")
  group by tq.test_id
  ;"))

  qbank_activity <- run_mysql_query(
    connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
    query = paste0(
    "select ta.user_id,
  ta.test_id,
  ta.id as attempt_id,
  aq.question_id,
  aq.is_correct,
  aq.earned_points,
  aq.total_points,
  aq.status,
  aq.hint_used,
  ta.created_at
  from LecturioQbank.test_attempts as ta
  join LecturioQbank.attempt_questions as aq on aq.attempt_id = ta.id
  where ta.user_id in (", paste0(user_ids, collapse = ", "), ")
  and ta.test_id in (", paste0(test_ids, collapse = ", "), ")
  ;"))

  # keep latest attempt only
  qbank_activity_f <- qbank_activity %>%
    group_by(user_id, test_id) %>%
    slice_max(order_by = created_at, n = 1, with_ties = TRUE) %>%
    ungroup() %>%
    mutate(is_correct = ifelse(status == 3 & hint_used == 0, is_correct, 0),
           earned_points = ifelse(status == 3 & hint_used == 0, earned_points, 0))

  # finalise data frame
  # n_questions, n_answered_questions, perc_answered_questions, n_correct, perc_correct, n_incorrect, perc_incorrect, n_total_points, n_earned_points, perc_earned_points
  user_qbank_activity <- users_tests %>%
    left_join(tests %>% mutate(n_questions = as.integer(n_questions)), by = "test_id") %>%
    left_join(qbank_activity_f, by = c("user_id", "test_id")) %>%
    group_by(user_id, test_id, is_randomized) %>%
    summarise(n_questions = max(n_questions),
              n_total_points = max(n_total_points),
              n_total_points_attempted = sum(total_points),
              n_answered_questions = sum(!is.na(question_id)),
              n_correct = sum(is_correct),
              n_earned_points = sum(earned_points),
              .groups = "drop"
    ) %>%
    replace_na(list(n_answered_questions = 0, n_correct = 0, n_earned_points = 0)) %>%
    mutate(n_total_points_attempted = ifelse(is.na(n_total_points_attempted), n_total_points, n_total_points_attempted),
           n_incorrect = n_answered_questions - n_correct) %>%
    select(user_id, test_id, is_randomized, n_questions, n_answered_questions,
           n_correct, n_incorrect,
           n_total_points = n_total_points_attempted, n_earned_points)

} # end qbank results


# get concept page results
get_cp_results <- function(user_cp){

  user_ids <- na.omit(unique(user_cp$user_id))
  cp_ids <- na.omit(unique(user_cp$cp_id))

  cp_activity <- run_mysql_query(
    connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
    query = paste0(
    "select topic_review_id as cp_id, user_id, learned_at, visits_counter
            from Lecturio.users_topic_reviews
            where topic_review_id in (", paste0(cp_ids, collapse = ','), ")
            and user_id in (", paste0(user_ids, collapse = ','), ")
            ;"))

  user_cp_ids <- user_cp %>%
    mutate(user_cp_id = paste(user_id, cp_id, sep = "-")) %>%
    pull(user_cp_id) %>%
    unique()

  cp_activity_f <- cp_activity %>%
    mutate(user_cp_id = paste(user_id, cp_id, sep = "-")) %>%
    filter(user_cp_id %in% user_cp_ids)

  user_cp_activity <- user_cp %>%
    unique() %>%
    left_join(cp_activity_f, by = c("user_id", "cp_id")) %>%
    mutate(n_cps = 1,
           n_visited_cps = ifelse(is.na(visits_counter), 0, 1),
           n_learned_cps = ifelse(is.na(learned_at), 0, 1)
    ) %>%
    select(user_id, cp_id, n_cps, n_visited_cps, n_learned_cps)

}


# get scorm page results
get_scorm_results <- function(user_scorms){

  user_ids <- na.omit(unique(user_scorms$user_id))
  scorm_ids <- na.omit(unique(user_scorms$scorm_id))

  # data on scorm package progress in mongo
  # use user course combination to find data
  source(paste0(Sys.getenv("path_common"), "R/run_mongo_query.R"))

  scorm_activity <- run_mongo_query(collection = "users_scorm_state", db = "users",
                                  query = paste0(
                                    '{"course_id" : { "$in" : [', paste0(scorm_ids, collapse = ", "), '] },
                  "user_id" : { "$in" : [', paste0(user_ids, collapse = ", "), '] } }'
                                  ))


  if(nrow(scorm_activity)){

    user_scorm_ids <- user_scorms %>%
      mutate(user_scorm_id = paste(user_id, scorm_id, sep = "-")) %>%
      pull(user_scorm_id) %>%
      unique()

    scorm_activity_f <- scorm_activity %>%
      rename(scorm_id = course_id) %>%
      mutate(user_scorm_id = paste(user_id, scorm_id, sep = "-")) %>%
      filter(user_scorm_id %in% user_scorm_ids)

  } else {

    scorm_activity_f <- data.frame(user_id = as.integer(), scorm_id = as.integer(),
                                   state_data = as.character(), is_completed = as.integer())

  }

  user_scorm_activity <- user_scorms %>%
    unique() %>%
    left_join(scorm_activity_f, by = c("user_id", "scorm_id")) %>%
    mutate(state_data = ifelse(state_data == "", NA, state_data),
           n_scorms = 1,
           n_started_scorms = ifelse(is.na(state_data), 0, 1),
           n_finished_scorms = ifelse(is.na(is_completed) | !is_completed, 0, 1)
    ) %>%
    select(user_id, scorm_id, n_scorms, n_started_scorms, n_finished_scorms)

}


get_assignment_lecture_progress <- function(assignments){
  ## lectures
  # get activity for lectures
  # Amount of Lectures  Number of Started Lectures      Percentage of Started Lectures  Number of Finished Lectures     Percentage of Finished Lectures
  # Amount of Questions Number of Answered Questions    Percentage of Answered Questions        Number of Questions Answered Correctly  Percentage of Questions Answered Correctly (in relation to answered questions)  Number of Questions Answered Incorrectly        Percentage of Questions Answered Incorrectly (in relation to answered questions)
  user_lectures <- assignments %>%
    filter(content_type == "lecture") %>%
    select(user_id, lecture_id = content_id) %>%
    unique()

  if(nrow(user_lectures)) {

    get_lecture_results(user_lectures) %>%
      left_join(user_lectures, by = c("user_id", "lecture_id")) %>%
      left_join(assignments %>%
                  filter(content_type == "lecture"),
                by = c("user_id", "lecture_id" = "content_id")) %>%
      # summarise by user_assignment_id, some assignments may have >1 lecture, concatenate content_ids
      group_by(user_id, assignment_id) %>%
      summarise(lecture_ids = paste(lecture_id, collapse = ", "),
                n_lectures = sum(n_lectures),
                n_started_lectures = sum(n_started_lectures),
                n_finished_lectures = sum(n_finished_lectures),
                n_questions = sum(n_questions, na.rm = TRUE),
                n_answered_questions = sum(n_answered_questions, na.rm = TRUE),
                n_correct = sum(n_correct, na.rm = TRUE),
                n_incorrect = sum(n_incorrect, na.rm = TRUE),
                .groups = "drop") %>%
      mutate(perc_started_lectures = n_started_lectures * 100,
             perc_finished_lectures = n_finished_lectures * 100,
             perc_answered_questions = ifelse(n_questions == 0, NA, n_answered_questions / n_questions * 100),
             perc_correct = ifelse(n_questions == 0, NA, n_correct / n_answered_questions * 100),
             perc_incorrect = ifelse(n_questions == 0, NA, n_incorrect / n_answered_questions * 100)
      ) %>%
      rename(content_id = lecture_ids)

  } else {

    data.frame(user_id = integer(), assignment_id = integer(), content_id = character())
  }
}


get_assignment_course_progress <- function(assignments){

  # get activity for courses
  user_courses <- assignments %>%
    filter(content_type == "course") %>%
    select(user_id, assignment_id, course_id = content_id) %>%
    unique()

  if(nrow(user_courses)) {

    ## lecture results ----
    # get lectures  for courses
    course_ids <- na.omit(unique(user_courses$course_id))
    lectures <- run_mysql_query(
    connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
    query = paste0(
      "select course_id, lecture_id
  from courses_lectures as cl
  join lectures as l on l.id = cl.lecture_id
      and l.is_live = 1 and l.is_removed = 0 and l.show_on_site = 1
  where course_id in (", paste0(course_ids, collapse = ", "), ")
  ;"))

    n_lectures_in_course <- data.frame(course_id = course_ids) %>%  # there are courses without lectures, I will give them n_lectures = 0 here
      left_join(lectures, by = "course_id") %>%
      group_by(course_id) %>%
      summarise(n_lectures = length(na.omit(unique(lecture_id))), .groups = "drop") %>%
      replace_na(list(n_lectures = 0))

    n_lectures_course_assignment <- n_lectures_in_course %>%
      left_join(assignments %>%
                  filter(content_type == "course") %>%
                  select(assignment_id, course_id = content_id) %>%
                  unique(),
                by = "course_id") %>%
      group_by(assignment_id) %>%
      summarise(n_lectures = sum(n_lectures),
                course_ids = paste(unique(course_id), collapse = ", "),
                .groups = "drop")

    user_lectures <- user_courses %>%
      left_join(lectures, by = c("course_id"), relationship = "many-to-many") %>%
      select(user_id, lecture_id) %>%
      unique()

    lecture_results <- get_lecture_results(user_lectures)

    # finalise data frame
    # n_lectures, n_started_lectures, perc_started_lectures, n_finished_lectures, perc_finished_lectures
    # n_questions, n_answered_questions, perc_answered_questions, n_correct, perc_correct, n_incorrect, perc_incorrect
    course_results <- user_courses %>%
      left_join(n_lectures_course_assignment, by = "assignment_id") %>%
      left_join(lectures, by = "course_id", relationship = "many-to-many") %>%
      # I need to summarise by assignment, one assignment could have more than one course and different courses may contain the same lectures
      # I will use the concatenated course_ids for the final output and add up the lecture progress per assignments, so I do not count lectures twice in teh same assignment
      select(-course_id) %>%
      unique() %>%
      # left_join(n_lectures_in_course, by = c("course_id")) %>%
      left_join(lecture_results %>% select(-n_lectures), by = c("user_id", "lecture_id")) %>%
      # summarise by assignment (can have more than 0 courses)
      group_by(assignment_id, user_id, course_ids) %>%
      summarise(n_lectures = max(n_lectures),
                n_started_lectures = sum(n_started_lectures),
                n_finished_lectures = sum(n_finished_lectures),
                n_questions = sum(n_questions, na.rm = TRUE),
                n_answered_questions = sum(n_answered_questions, na.rm = TRUE),
                n_correct = sum(n_correct, na.rm = TRUE),
                n_incorrect = sum(n_incorrect, na.rm = TRUE),
                .groups = "drop"
      ) %>%
      mutate(perc_started_lectures = n_started_lectures/n_lectures * 100,
             perc_finished_lectures = n_finished_lectures/n_lectures * 100,
             perc_answered_questions = ifelse(n_questions == 0, NA, n_answered_questions/n_questions * 100),
             perc_correct = ifelse(n_questions == 0, NA, n_correct/n_answered_questions * 100),
             perc_incorrect = ifelse(n_questions == 0, NA, n_incorrect/n_answered_questions * 100)
      ) %>%
      select(assignment_id, user_id, course_ids, n_lectures, n_started_lectures, perc_started_lectures, n_finished_lectures, perc_finished_lectures,
             n_questions, n_answered_questions, perc_answered_questions, n_correct, perc_correct, n_incorrect, perc_incorrect)

    ## course exams -----
    # Mandatory  Pass result  Has exam  Exam status  Exam passed/failed date (GMT)
    # get exam results if there are exams
    user_exams <- assignments %>%
      # has_exam is mutated to a clean 0/1 flag upstream
      filter(has_exam == 1, content_type == "course") %>%
      select(user_id, assignment_id, content_id, has_exam) %>%
      unique()

    if(nrow(user_exams)){
      exam_results <- get_exam_results(user_exams, content_type = "course")
      exam_course_results <- user_exams %>%
        left_join(exam_results, by = c("user_id", "content_id")) %>%
        group_by(assignment_id, user_id) %>%
        summarise(n_exams = sum(has_exam),
                  has_passed = sum(has_passed),
                  exam_passed_failed_date_UTC = max(exam_passed_failed_date_UTC), .groups = "drop") %>%
        # in the rare case that there are 2 courses in an assignment with an exam each, if one of the exams is not done count as "not attempted" for assignment
        mutate(pass_result = ifelse(has_passed == n_exams, "passed", "failed"),
               exam_status = ifelse(is.na(pass_result), "not attempted", "completed")) %>%
        select(assignment_id, user_id, exam_status, pass_result, exam_passed_failed_date_UTC)

    } else {
      exam_course_results <- data.frame(assignment_id = integer(),
                                        user_id = integer(),
                                        exam_status = character(),
                                        pass_result = character(),
                                        exam_passed_failed_date_UTC = as.POSIXct(character()))
    }

    ## finalize course results -----
    course_results %>%
      left_join(exam_course_results, by = c("user_id", "assignment_id")) %>%
      rename(content_id = course_ids)

  } else {

    data.frame(user_id = integer(), assignment_id = integer(), content_id = character())

  }
}


get_assignment_qbank_progress <- function(assignments){

  # get activity for qbank tests
  user_tests <- assignments %>%
    filter(content_type == "qbank_test") %>%
    select(user_id, test_id = content_id) %>%
    unique()

  if(nrow(user_tests)) {
    # get qbank results
    get_qbank_results(user_tests) %>%
      left_join(assignments %>%
                  filter(content_type == "qbank_test"),
                by = c("user_id", "test_id" = "content_id")) %>%
      group_by(assignment_id, user_id) %>%
      summarise(test_ids = paste(test_id, collapse = ", "),
                n_questions_test = sum(n_questions),
                n_answered_questions_test = sum(n_answered_questions),
                n_correct_test = sum(n_correct),
                n_incorrect_test = sum(n_incorrect),
                n_total_points_test = sum(n_total_points),
                n_earned_points_test= sum(n_earned_points),
                .groups = "drop") %>%
      mutate(perc_answered_questions_test = n_answered_questions_test/n_questions_test * 100,
             perc_correct_test = ifelse(n_answered_questions_test == 0, NA, n_correct_test/n_answered_questions_test * 100),
             perc_incorrect_test = ifelse(n_answered_questions_test == 0, NA, n_incorrect_test/n_answered_questions_test * 100),
             perc_earned_points_test = ifelse(n_answered_questions_test == 0, NA, n_earned_points_test/n_total_points_test * 100)
      ) %>%
      rename(content_id = test_ids)

  } else {

    data.frame(user_id = integer(), assignment_id = integer(), content_id = character())

  }

}


get_assignment_lp_progress <- function(assignments) {

  # get activity for learning paths (catalog categories)
  user_lps <- assignments %>%
    filter(content_type == "catalog_category") %>%
    select(user_id, assignment_id, lp_id = content_id, assignment_assigned_at) %>%
    unique()

  if(nrow(user_lps)) {
    # can have all of the individual content types!, lectures/quiz questions need to be summarised per LP
    ## content for lps -----
    lp_ids <- run_mysql_query(
    connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
    query = paste0(
      "select cc.id as lp_id, cc.title as lp, cc2.id as lp_child_id, cc2.title as lp_child,
      cc2.deleted_at
  from catalog_categories as cc
  left join catalog_categories as cc2 on cc2.parent_id = cc.id
  where cc.id in (", paste0(unique(user_lps$lp_id), collapse = ", "), ")
  and (cc2.is_published = 1 or cc2.is_published is null)
  ;"))


    category_ids <- na.omit(unique(c(lp_ids$lp_id, lp_ids$lp_child_id)))
    lp_items <- run_mysql_query(
    connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
    query = paste0(
      "select catalog_category_id, item_type, item_id, order_num
          from catalog_category_items
          where catalog_category_id in (", paste0(category_ids, collapse = ','), ")
          ;"))

    # if child id then link link items to parent id
    lp_items_by_assignment <- user_lps %>%
      mutate(lp_child_id = lp_id) %>%
      select(lp_id, lp_child_id) %>%
      unique() %>%
      bind_rows(lp_ids %>%
                  select(lp_id, lp_child_id, deleted_at)) %>%
      left_join(lp_items, by = c("lp_child_id" = "catalog_category_id"), relationship = "many-to-many") %>%
      left_join(user_lps, by = "lp_id", relationship = "many-to-many") %>%
      filter(!is.na(item_id),
             # if deleted_at date is before the date of the assignment, then the step (lp_child) is not part of the assignment
             is.na(deleted_at) | deleted_at > assignment_assigned_at) %>%
      select(assignment_id, user_id, lp_id, item_id, item_type) %>%
      unique()


    # 1 course
    # 2 test (qbank)
    # 3 instruction - out of scope
    # 4 concept page - out of scope
    # 5 final exam
    # 6 external video - out of scope
    # 7 scorm package (interactive learning item) - out of scope

    ## course results for lp -----
    user_courses <- lp_items_by_assignment %>%
      filter(item_type == 1) %>%
      select(user_id, assignment_id, lp_id, course_id = item_id) %>%
      filter(!is.na(course_id))


    if(nrow(user_courses)) {
      # get lectures  for courses
      course_ids <- na.omit(unique(user_courses$course_id))
      lectures <- run_mysql_query(
    connection_type = Sys.getenv("MYSQL_CONNECTION_TYPE"), db = "lecturio-live",
    query = paste0(
        "select course_id, lecture_id
  from courses_lectures as cl
  join lectures as l on l.id = cl.lecture_id
      and l.is_live = 1 and l.is_removed = 0 and l.show_on_site = 1
  where course_id in (", paste0(course_ids, collapse = ", "), ")
  ;"))

      n_lectures_in_course <- data.frame(course_id = course_ids) %>%  # there are courses without lectures, I will give them n_lectures = 0 here
        left_join(lectures, by = "course_id") %>%
        group_by(course_id) %>%
        summarise(n_lectures = length(na.omit(unique(lecture_id))), .groups = "drop") %>%
        replace_na(list(n_lectures = 0))

      n_lectures_course_assignment <- n_lectures_in_course %>%
        left_join(user_courses %>%
                    select(assignment_id, lp_id, course_id) %>%
                    unique(),
                  by = "course_id") %>%
        group_by(assignment_id) %>%
        summarise(n_lectures = sum(n_lectures),
                  lp_ids = paste(unique(lp_id), collapse = ", "),
                  course_ids = paste(unique(course_id), collapse = ", "),
                  .groups = "drop")

      user_lectures <- user_courses %>%
        left_join(lectures, by = c("course_id"), relationship = "many-to-many") %>%
        select(user_id, lecture_id) %>%
        unique()

      lecture_results <- get_lecture_results(user_lectures)


      lp_course_results <- user_courses %>%
        left_join(n_lectures_course_assignment, by = "assignment_id") %>%
        left_join(lectures, by = "course_id", relationship = "many-to-many") %>%
        # I need to summarise by assignment, one assignment could have more than one course and different courses may contain the same lectures
        # I will use the concatenated course_ids for the final output and add up the lecture progress per assignments, so I do not count lectures twice in teh same assignment
        select(-course_id) %>%
        unique() %>%
        left_join(lecture_results %>% select(-n_lectures), by = c("user_id", "lecture_id")) %>%
        # summarise by lp
        group_by(user_id, assignment_id, lp_ids) %>%
        summarise(n_lectures = max(n_lectures),
                  n_started_lectures = sum(n_started_lectures),
                  n_finished_lectures = sum(n_finished_lectures),
                  n_questions = sum(n_questions, na.rm = TRUE),
                  n_answered_questions = sum(n_answered_questions, na.rm = TRUE),
                  n_correct = sum(n_correct, na.rm = TRUE),
                  n_incorrect = sum(n_incorrect, na.rm = TRUE),
                  .groups = "drop"
        ) %>%
        mutate(perc_started_lectures = n_started_lectures/n_lectures * 100,
               perc_finished_lectures = n_finished_lectures/n_lectures * 100,
               perc_answered_questions = n_answered_questions/n_questions * 100,
               perc_correct = n_correct/n_answered_questions * 100,
               perc_incorrect = n_incorrect/n_answered_questions * 100
        ) %>%
        select(user_id, assignment_id, lp_ids, n_lectures,
               n_started_lectures, perc_started_lectures,
               n_finished_lectures, perc_finished_lectures,
               n_questions, n_answered_questions, perc_answered_questions,
               n_correct, perc_correct, n_incorrect, perc_incorrect)
    } else {
      lp_course_results <- data.frame(
        user_id = integer(),
        assignment_id = integer(),
        lp_ids = character(),
        n_lectures = integer(),
        n_started_lectures = integer(),
        perc_started_lectures = numeric(),
        n_finished_lectures = integer(),
        perc_finished_lectures = numeric(),
        n_questions = integer(),
        n_answered_questions = integer(),
        perc_answered_questions = numeric(),
        n_correct = integer(),
        perc_correct = numeric(),
        n_incorrect = integer(),
        perc_incorrect = numeric()
      )
    }

    ## qbank test results for lp -----
    user_lp_tests <- lp_items_by_assignment %>%
      filter(item_type == 2) %>%
      select(user_id, assignment_id, lp_id, test_id = item_id) %>%
      filter(!is.na(test_id))

    user_tests <- user_lp_tests %>%
      select(user_id, test_id) %>%
      unique()

    if(nrow(user_tests)){
      qbank_results <- get_qbank_results(user_tests)

      # finalize dataframe
      lp_qbank_results <- user_lp_tests %>%
        left_join(qbank_results, by = c("user_id", "test_id")) %>%
        group_by(user_id, assignment_id) %>%
        summarise(lp_ids = paste(unique(lp_id), collapse = ", "),
                  n_questions_test = sum(n_questions, na.rm = TRUE),
                  n_answered_questions_test = sum(n_answered_questions, na.rm = TRUE),
                  n_correct_test = sum(n_correct, na.rm = TRUE),
                  n_incorrect_test = sum(n_incorrect, na.rm = TRUE),
                  n_total_points_test = sum(n_total_points, na.rm = TRUE),
                  n_earned_points_test = sum(n_earned_points, na.rm = TRUE),
                  .groups = "drop"
        ) %>%
        mutate(perc_answered_questions_test = n_answered_questions_test/n_questions_test * 100,
               perc_correct_test = ifelse(n_answered_questions_test == 0, NA, n_correct_test/n_answered_questions_test * 100),
               perc_incorrect_test = ifelse(n_answered_questions_test == 0, NA, n_incorrect_test/n_answered_questions_test * 100),
               perc_earned_points_test = ifelse(n_answered_questions_test == 0, NA, n_earned_points_test/n_total_points_test * 100)
        ) %>%
        select(user_id, assignment_id, lp_ids, n_questions_test, n_answered_questions_test, perc_answered_questions_test,
               n_correct_test, perc_correct_test, n_incorrect_test, perc_incorrect_test, n_total_points_test,
               n_earned_points_test, perc_earned_points_test)
    } else {
      lp_qbank_results <- data.frame(
        user_id = integer(),
        assignment_id = integer(),
        lp_ids = character(),
        n_questions_test = integer(),
        n_answered_questions_test = integer(),
        perc_answered_questions_test = numeric(),
        n_correct_test = integer(),
        perc_correct_test = numeric(),
        n_incorrect_test = integer(),
        perc_incorrect_test = numeric(),
        n_total_points_test = integer(),
        n_earned_points_test = integer(),
        perc_earned_points_test = numeric()
      )
    }

    ## exam results for lp -----
    user_lp_exams <- lp_items_by_assignment %>%
      filter(item_type == 5) %>%
      filter(!is.na(item_id)) %>%
      select(user_id, assignment_id, content_id = lp_id) # item_id for final exams is always 0, we match via catalog_category_id!!!

    user_exams <- user_lp_exams %>%
      select(user_id, content_id) %>%
      unique()

    if(nrow(user_exams)){
      exam_results <- get_exam_results(user_exams, content_type = "lp")
      lp_exam_results <- user_lp_exams %>%
        mutate(has_exam = 1) %>%
        left_join(exam_results, by = c("user_id", "content_id")) %>%
        group_by(user_id, assignment_id) %>%
        summarise(lp_ids = paste(unique(content_id), collapse = ", "),
                  n_exams = sum(has_exam),
                  has_passed = sum(has_passed),
                  exam_passed_failed_date_UTC = max(exam_passed_failed_date_UTC),
                  .groups = "drop") %>%
        mutate(pass_result = ifelse(has_passed == n_exams, "passed", "failed"),
               exam_status = ifelse(is.na(pass_result), "not attempted", "completed")) %>%
        select(assignment_id, user_id, lp_ids, exam_status, pass_result, exam_passed_failed_date_UTC)
    } else {
      lp_exam_results <- data.frame(assignment_id = integer(),
                                    user_id = integer(),
                                    lp_ids = character(),
                                    exam_status = character(),
                                    pass_result = character(),
                                    exam_passed_failed_date_UTC = as.POSIXct(character()))
    }


    ## concept page results for lp ----
    user_lp_cps <- lp_items_by_assignment %>%
      filter(item_type == 4) %>%
      select(user_id, assignment_id, lp_id, cp_id = item_id) %>%
      filter(!is.na(cp_id))

    user_cps <- user_lp_cps %>%
      select(user_id, cp_id) %>%
      unique()

    if(nrow(user_cps)){
      cp_results <- get_cp_results(user_cps)

      # finalize dataframe
      lp_cp_results <- user_lp_cps %>%
        left_join(cp_results, by = c("user_id", "cp_id")) %>%
        group_by(user_id, assignment_id) %>%
        summarise(lp_ids = paste(unique(lp_id), collapse = ", "),
                  n_cps = sum(n_cps, na.rm = TRUE),
                  n_visited_cps = sum(n_visited_cps, na.rm = TRUE),
                  n_learned_cps = sum(n_learned_cps, na.rm = TRUE),
                  .groups = "drop"
        ) %>%
        mutate(perc_visited_cps = n_visited_cps/n_cps * 100,
               perc_learned_cps = n_learned_cps/n_cps * 100
        ) %>%
        select(user_id, assignment_id, lp_ids, n_cps, n_visited_cps, perc_visited_cps,
               n_learned_cps, perc_learned_cps)

    } else {

      lp_cp_results <- data.frame(
        user_id = integer(),
        assignment_id = integer(),
        lp_ids = character(),
        n_cps = integer(),
        n_visited_cps = integer(),
        perc_visited_cps = numeric(),
        n_learned_cps = integer(),
        perc_learned_cps = numeric()
      )

    }


    ## scorm results for lp -----
    user_lp_scorms <- lp_items_by_assignment %>%
      filter(item_type == 7) %>%
      select(user_id, assignment_id, lp_id, scorm_id = item_id) %>%
      filter(!is.na(scorm_id))

    user_scorms <- user_lp_scorms %>%
      select(user_id, scorm_id) %>%
      unique()

    if(nrow(user_scorms)){

      scorm_results <- get_scorm_results(user_scorms)

      # finalize dataframe
      lp_scorm_results <- user_lp_scorms %>%
        left_join(scorm_results, by = c("user_id", "scorm_id")) %>%
        group_by(user_id, assignment_id) %>%
        summarise(lp_ids = paste(unique(lp_id), collapse = ", "),
                  n_scorms = sum(n_scorms, na.rm = TRUE),
                  n_started_scorms = sum(n_started_scorms, na.rm = TRUE),
                  n_finished_scorms = sum(n_finished_scorms, na.rm = TRUE),
                  .groups = "drop"
        ) %>%
        mutate(perc_started_scorms = n_started_scorms/n_scorms * 100,
               perc_finished_scorms = n_finished_scorms/n_scorms * 100
        ) %>%
        select(user_id, assignment_id, lp_ids, n_scorms, n_started_scorms, perc_started_scorms,
               n_finished_scorms, perc_finished_scorms)

    } else {

      lp_scorm_results <- data.frame(
        user_id = integer(),
        assignment_id = integer(),
        lp_ids = character(),
        n_scorms = integer(),
        n_started_scorms = integer(),
        perc_started_scorms = numeric(),
        n_finished_scorms = integer(),
        perc_finished_scorms = numeric()
      )

    } # end scorm results

    ## single lesson results for lp ----
    user_lp_sls <- lp_items_by_assignment %>%
      filter(item_type == 9) %>%
      select(user_id, assignment_id, lp_id, lecture_id = item_id) %>%
      filter(!is.na(lecture_id))

    user_sls <- user_lp_sls %>%
      select(user_id, lecture_id) %>%
      unique()

    if(nrow(user_sls)){
      sl_results <- get_lecture_results(user_sls)

      # finalize dataframe
      lp_sl_results <- user_lp_sls %>%
        left_join(sl_results, by = c("user_id", "lecture_id")) %>%
        group_by(user_id, assignment_id) %>%
        summarise(lp_ids = paste(unique(lp_id), collapse = ", "),
                  n_lectures = max(n_lectures),
                  n_started_lectures = sum(n_started_lectures),
                  n_finished_lectures = sum(n_finished_lectures),
                  n_questions = sum(n_questions, na.rm = TRUE),
                  n_answered_questions = sum(n_answered_questions, na.rm = TRUE),
                  n_correct = sum(n_correct, na.rm = TRUE),
                  n_incorrect = sum(n_incorrect, na.rm = TRUE),
                  .groups = "drop"
        ) %>%
        mutate(perc_started_lectures = n_started_lectures/n_lectures * 100,
               perc_finished_lectures = n_finished_lectures/n_lectures * 100,
               perc_answered_questions = n_answered_questions/n_questions * 100,
               perc_correct = n_correct/n_answered_questions * 100,
               perc_incorrect = n_incorrect/n_answered_questions * 100
        ) %>%
        select(user_id, assignment_id, lp_ids, n_lectures,
               n_started_lectures, perc_started_lectures,
               n_finished_lectures, perc_finished_lectures,
               n_questions, n_answered_questions, perc_answered_questions,
               n_correct, perc_correct, n_incorrect, perc_incorrect)

    } else {

      lp_sl_results <- data.frame(
        user_id = integer(),
        assignment_id = integer(),
        lp_ids = character(),
        n_lectures = integer(),
        n_started_lectures = integer(),
        perc_started_lectures = numeric(),
        n_finished_lectures = integer(),
        perc_finished_lectures = numeric(),
        n_questions = integer(),
        n_answered_questions = integer(),
        perc_answered_questions = numeric(),
        n_correct = integer(),
        perc_correct = numeric(),
        n_incorrect = integer(),
        perc_incorrect = numeric()
      )
    } # end single lesson results

    ## combine course and single lesson progress -----
    lp_course_sl_results <- lp_course_results %>%
      rbind(lp_sl_results) %>%
      group_by(user_id, assignment_id, lp_ids) %>%
      summarise(n_lectures = sum(n_lectures),
                n_started_lectures = sum(n_started_lectures),
                n_finished_lectures = sum(n_finished_lectures),
                n_questions = sum(n_questions, na.rm = TRUE),
                n_answered_questions = sum(n_answered_questions, na.rm = TRUE),
                n_correct = sum(n_correct, na.rm = TRUE),
                n_incorrect = sum(n_incorrect, na.rm = TRUE),
                .groups = "drop"
      ) %>%
      mutate(perc_started_lectures = n_started_lectures/n_lectures * 100,
             perc_finished_lectures = n_finished_lectures/n_lectures * 100,
             perc_answered_questions = n_answered_questions/n_questions * 100,
             perc_correct = n_correct/n_answered_questions * 100,
             perc_incorrect = n_incorrect/n_answered_questions * 100
      ) %>%
      select(user_id, assignment_id, lp_ids, n_lectures,
             n_started_lectures, perc_started_lectures,
             n_finished_lectures, perc_finished_lectures,
             n_questions, n_answered_questions, perc_answered_questions,
             n_correct, perc_correct, n_incorrect, perc_incorrect)

    ## finalize lp results -----
    lp_course_sl_results %>%
      full_join(lp_qbank_results, by = c("user_id", "assignment_id", "lp_ids")) %>%
      full_join(lp_exam_results, by = c("user_id", "assignment_id", "lp_ids")) %>%
      full_join(lp_cp_results, by = c("user_id", "assignment_id", "lp_ids")) %>%
      full_join(lp_scorm_results, by = c("user_id", "assignment_id", "lp_ids")) %>%
      rename(content_id = lp_ids)

  } else {

    data.frame(user_id = integer(), assignment_id = integer(), content_id = character())

  }

}
