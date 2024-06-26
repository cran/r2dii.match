#' Pick rows where `score` is 1 and `level` per loan is of highest `priority`
#'
#' When multiple perfect matches are found per loan (e.g. a match at
#' `direct_loantaker` level and `ultimate_parent` level), we must prioritize the
#' desired match. By default, the highest `priority` is the most granular match
#' (i.e. `direct_loantaker`).
#'
#' @template ignores-but-preserves-existing-groups
#'
#' @param data A data frame like the validated output of [match_name()]. See
#'  _Details_ on how to validate `data`.
#' @param priority One of:
#'   * `NULL`: defaults to the default level priority as returned by
#'   [prioritize_level()].
#'   * A character vector giving a custom priority.
#'   * A function to apply to the output of [prioritize_level()], e.g. `rev`.
#'   * A quosure-style lambda function, e.g. `~ rev(.x)`.
#'
#' @seealso [match_name()], [prioritize_level()].
#' @family main functions
#'
#' @details
#' **How to validate `data`**
#' Write the output of `match_name()` into a .csv file with:
#' 
#' ```
#' # Writting to current working directory
#' matched %>%
#'   readr::write_csv("matched.csv")
#' ```
#' 
#' Compare, edit, and save the data manually:
#' 
#' * Open _matched.csv_ with any spreadsheet editor (Excel, Google Sheets, etc.).
#' * Compare the columns `name` and `name_abcd` manually to determine if the match is valid. Other information can be used in conjunction with just the names to ensure the two entities match (sector, internal information on the company structure, etc.)
#' * Edit the data:
#'     * If you are happy with the match, set the `score` value to `1`.
#'     * Otherwise set or leave the `score` value to anything other than `1`.
#' * Save the edited file as, say, _valid_matches.csv_.
#' 
#' Re-read the edited file (validated) with:
#' 
#' ```
#' # Reading from current working directory
#' valid_matches <- readr::read_csv("valid_matches.csv")
#' ```
#'
#' @return A data frame with a single row per loan, where `score` is 1 and
#'   priority level is highest.
#'
#' @export
#'
#' @examples
#' library(dplyr)
#'
#' # styler: off
#' matched <- tribble(
#'   ~sector, ~sector_abcd,  ~score, ~id_loan,                ~level,
#'    "coal",      "coal",       1,     "aa",     "ultimate_parent",
#'    "coal",      "coal",       1,     "aa",    "direct_loantaker",
#'    "coal",      "coal",       1,     "bb", "intermediate_parent",
#'    "coal",      "coal",       1,     "bb",     "ultimate_parent",
#' )
#' # styler: on
#'
#' prioritize_level(matched)
#'
#' # Using default priority
#' prioritize(matched)
#'
#' # Using the reverse of the default priority
#' prioritize(matched, priority = rev)
#'
#' # Same
#' prioritize(matched, priority = ~ rev(.x))
#'
#' # Using a custom priority
#' bad_idea <- c("intermediate_parent", "ultimate_parent", "direct_loantaker")
#'
#' prioritize(matched, priority = bad_idea)
prioritize <- function(data, priority = NULL) {
  if (has_zero_rows(data)) {
    return(data)
  }

  data %>%
    check_crucial_names(
      c("id_loan", "level", "score", "sector", "sector_abcd")
    ) %>%
    check_duplicated_score1()

  priority <- set_priority(data, priority = priority)

  old_groups <- dplyr::groups(data)
  perfect_matches <- filter(ungroup(data), .data$score == 1L)

  out <- perfect_matches %>%
    group_by(.data$id_loan, .data$sector, .data$sector_abcd) %>%
    prioritize_at(.at = "level", priority = priority) %>%
    ungroup()

  group_by(out, !!!old_groups)
}

has_zero_rows <- function(data) {
  !nrow(data) > 0L
}

check_duplicated_score1 <- function(data) {
  score_1 <- filter(data, .data$score == 1)
  # The only important side effect of this function if to abort duplicated rows
  loan_level <- suppressMessages(select(score_1, all_of(c("id_loan", "level"))))
  is_duplicated <- duplicated(loan_level)

  if (!any(is_duplicated)) {
    return(invisible(data))
  }

  duplicated_rows <- commas(rownames(data)[is_duplicated])
  abort(
    class = "duplicated_score1_by_id_loan_by_level",
    message = glue(
      "`data` where `score` is `1` must be unique by `id_loan` by `level`.
     Duplicated rows: {duplicated_rows}.
     Have you ensured that only one abcd-name per loanbook-name is set to `1`?"
    )
  )
}

set_priority <- function(data, priority) {
  priority <- priority %||% prioritize_level(data)

  if (inherits(priority, "function")) {
    f <- priority
    priority <- f(prioritize_level(data))
  }

  if (inherits(priority, "formula")) {
    f <- rlang::as_function(priority)
    priority <- f(prioritize_level(data))
  }

  known_levels <- sort(unique(data$level))
  unknown_levels <- setdiff(priority, known_levels)
  if (!identical(unknown_levels, character(0))) {
    rlang::warn(
      glue(
        "Ignoring `priority` levels not found in data: \\
        {paste0(unknown_levels, collapse = ', ')}
        Did you mean to use one of: {paste0(known_levels, collapse = ', ')}?"
      )
    )
  }

  priority
}

#' Arrange unique `level` values in default order of `priority`
#'
#' @param data A data frame, commonly the output of [match_name()].
#'
#' @family helpers
#'
#' @return A character vector of the default level priority per loan.
#' @export
#'
#' @examples
#' matched <- tibble::tibble(
#'   level = c(
#'     "intermediate_parent_1",
#'     "direct_loantaker",
#'     "direct_loantaker",
#'     "direct_loantaker",
#'     "ultimate_parent",
#'     "intermediate_parent_2"
#'   )
#' )
#' prioritize_level(matched)
prioritize_level <- function(data) {
  select_chr(
    # Sort sufixes: e.g. intermediate*1, *2, *n
    sort(unique(data$level)),
    tidyselect::matches("direct"),
    tidyselect::matches("intermediate"),
    tidyselect::matches("ultimate")
  )
}

#' Pick rows from a data frame based on a priority set at some columns
#'
#' @param data A data frame.
#' @param .at Most commonly, a character vector of one column name. For more
#'   general usage see the `.vars` argument to [dplyr::arrange_at()].
#' @param priority Most commonly, a character vector of the priority to
#'   re-order the column(x) given by `.at`.
#'
#' @return A data frame, commonly with less rows than the input.
#'
#' @examples
#' library(dplyr)
#'
#' # styler: off
#' data <- tibble::tribble(
#'   ~x,  ~y,
#'    1, "a",
#'    2, "a",
#'    2, "z",
#' )
#' # styler: on
#'
#' data %>% prioritize_at("y")
#'
#' data %>%
#'   group_by(x) %>%
#'   prioritize_at("y")
#'
#' data %>%
#'   group_by(x) %>%
#'   prioritize_at(.at = "y", priority = c("z", "a")) %>%
#'   arrange(x) %>%
#'   ungroup()
#' @noRd
prioritize_at <- function(data, .at, priority = NULL) {
  data %>%
    dplyr::arrange_at(.at, .funs = relevel2, new_levels = priority) %>%
    dplyr::filter(dplyr::row_number() == 1L)
}

relevel2 <- function(f, new_levels) {
  factor(f, levels = c(new_levels, setdiff(levels(f), new_levels)))
}
