#' Reproducible HTML document
#'
#' The output format \code{wflow_html} automatically 1) sets a seed with
#' \code{\link{set.seed}}, 2) inserts version of Git repo, and 3) inserts
#' \code{\link{sessionInfo}}.
#'
#' @param ... Arguments passed to \code{\link[rmarkdown]{html_document}}
#'
#' @return \code{\link[rmarkdown]{output_format}}
#'
#' @import rmarkdown
#' @export
wflow_html <- function(...) {

  # knitr options --------------------------------------------------------------

  # Save the figures in "figure/<basename-of-Rmd-file>/"
  # https://yihui.name/knitr/hooks/#option-hooks
  hook_fig_path <- function(options) {
    options$fig.path <- file.path("figure", knitr::current_input(), "")
    return(options)
  }
  plot_hook <- function(x, options) {
    if (git2r::in_repository(".")) {
      r <- git2r::repository(".", discover = TRUE)

      input <- file.path(getwd(), x)

      # Need to refactor obtaining workflowr options
      github = get_github_from_remote(getwd())
      output_dir <- get_output_dir(directory = getwd())
      if (!is.null(output_dir)) {
        input <- file.path(output_dir, x)
      }

      fig_versions <- get_versions_fig(fig = input, r = r, github = github)

      if (fig_versions == "") {
        return(sprintf("![](%s)", x))
      } else {
        paste(c(sprintf("![](%s)\n", x),
                fig_versions),
              collapse = "\n")
      }
    } else {
      return(sprintf("![](%s)", x))
    }
  }

  knitr <- rmarkdown::knitr_options(opts_chunk = list(comment = NA,
                                                      fig.align = "center",
                                                      tidy = FALSE),
                                    knit_hooks = list(plot = plot_hook),
                                    opts_hooks = list(fig.path = hook_fig_path))

  # pre_knit function ----------------------------------------------------------

  # This function copies the R Markdown file to a temporary directory and then
  # modifies it.
  pre_knit <- function(input, ...) {

    # Access parent environment. Have to go up 2 frames because of the function
    # that combines pre_knit function from the current and base output_formats.
    #
    # Inspired by rmarkdowntown by Romain François
    # https://github.com/romainfrancois/rmarkdowntown/blob/deef97a5cd6f0592318ecc6e78c6edd7612eb449/R/html_document2.R#L12
    frames <- sys.frames()
    e <- frames[[length(frames) - 2]]

    lines_in <- readLines(input)
    tmpfile <- file.path(tempdir(), basename(input))
    e$knit_input <- tmpfile

    # Default wflow options
    wflow_opts <- list(knit_root_dir = NULL,
                        seed = 12345,
                        github = get_github_from_remote(dirname(input)),
                        sessioninfo = "sessionInfo()")

    # Get options from a potential _workflowr.yml file
    wflow_root <- try(rprojroot::find_root(rprojroot::has_file("_workflowr.yml"),
                                            path = dirname(input)), silent = TRUE)
    if (class(wflow_root) != "try-error") {
      wflow_yml <- file.path(wflow_root, "_workflowr.yml")
      wflow_yml_opts <- yaml::yaml.load_file(wflow_yml)
      for (opt in names(wflow_yml_opts)) {
        wflow_opts[[opt]] <- wflow_yml_opts[[opt]]
      }
      # If knit_root_dir is a relative path, interpret it as relative to the
      # location of _workflowr.yml
      if (!is.null(wflow_opts$knit_root_dir)) {
        if (!R.utils::isAbsolutePath(wflow_opts$knit_root_dir)) {
          wflow_opts$knit_root_dir <- absolute(file.path(wflow_root,
                                                          wflow_opts$knit_root_dir))
        }
      }
    }

    # Get potential options from YAML header. These override the options
    # specified in _workflowr.yml.
    header <- rmarkdown::yaml_front_matter(input)
    header_opts <- header$wflow
    for (opt in names(header_opts)) {
      wflow_opts[[opt]] <- header_opts[[opt]]
    }
    # If knit_root_dir was specified as a relative path in the YAML header,
    # interpret it as relative to the location of the file
    if (!is.null(wflow_opts$knit_root_dir)) {
      if (!R.utils::isAbsolutePath(wflow_opts$knit_root_dir)) {
        wflow_opts$knit_root_dir <- absolute(file.path(dirname(input),
                                                        wflow_opts$knit_root_dir))
      }
    }

    # If knit_root_dir hasn't been configured in _workflowr.yml or the YAML header,
    # set it to the location of the original file
    if (is.null(wflow_opts$knit_root_dir)) {
      wflow_opts$knit_root_dir <- dirname(normalizePath(input))
    }

    # Set the knit_root_dir option for rmarkdown::render. However, the user can
    # override the knit_root_dir option by passing it directly to render.
    if (is.null(e$knit_root_dir)) {
      e$knit_root_dir <- wflow_opts$knit_root_dir
    } else {
      wflow_opts$knit_root_dir <- e$knit_root_dir
    }

    # Find the end of the YAML header for inserting new lines
    header_delims <- stringr::str_which(lines_in, "^-{3}|^\\.{3}")
    header_end <- header_delims[2]
    insert_point <- header_end

    # Get output directory if it exists
    output_dir <- get_output_dir(directory = dirname(input))

    has_code <- detect_code(input)

    report <- create_report(input, output_dir, has_code, wflow_opts)

    # Set seed at beginning
    if (has_code && is.numeric(wflow_opts$seed) && length(wflow_opts$seed) == 1) {
      seed_chunk <- c("",
                      "```{r seed-set-by-workflowr, echo = FALSE}",
                      sprintf("set.seed(%d)", wflow_opts$seed),
                      "```",
                      "")
    } else {
      seed_chunk <- ""
    }

    # Add session information at the end
    if (has_code && wflow_opts$sessioninfo != "") {
      sessioninfo <- c("",
                       "## Session information",
                       "",
                       "```{r session-info-chunk-inserted-by-workflowr}",
                       wflow_opts$sessioninfo,
                       "```",
                       "")
    } else {
      sessioninfo <- ""
    }

    lines_out <- c(lines_in[1:header_end],
                   "**Last updated:** `r Sys.Date()`",
                   report,
                   "---",
                   seed_chunk,
                   lines_in[(header_end + 1):length(lines_in)],
                   sessioninfo)

    writeLines(lines_out, tmpfile)
  }

  # post_knit function ---------------------------------------------------------

  # This function adds the navigation bar for websites defined in either
  # _navbar.html or _site.yml. Below I just fix the path to the input file that
  # I had changed for pre_knit and then execute the post_knit from
  # rmarkdown::html_document.
  post_knit <- function(metadata, input_file, runtime, encoding, ...) {

    # Change the input_file back to its original so that the post_knit defined
    # in rmarkdown::html_document() can find the navbar defined in _site.yml.
    input_file_original <- file.path(getwd(), basename(input_file))
    # I tried to find a better solution than directly calling it myself (since
    # it is run afterwards anyways since html_document() is the base format),
    # but nothing I tried worked.
    rmarkdown::html_document()$post_knit(metadata, input_file_original,
                                         runtime, encoding, ...)
  }

  # pre_processor function -----------------------------------------------------

  # Pass additional arguments to Pandoc. I use this to add a custom footer.
  pre_processor <- function(metadata, input_file, runtime, knit_meta,
                            files_dir, output_dir) {
    fname_footer <- tempfile("footer", fileext = ".html")
    wflow_version <- utils::packageVersion("workflowr")
    footer <- c("<hr>",
                "<p>",
                "This reproducible <a href=\"http://rmarkdown.rstudio.com\">R
                Markdown</a> analysis was created with <a
                href=\"https://github.com/jdblischak/workflowr\">workflowr</a> ",
                as.character(wflow_version),
                "</p>",
                "<hr>")
    writeLines(footer, con = fname_footer)
    args <- c("--include-after-body", fname_footer)
    return(args)
  }

  # Return ---------------------------------------------------------------------

  o <- rmarkdown::output_format(knitr = knitr,
                                pandoc = pandoc_options(to = "html"),
                                pre_knit = pre_knit,
                                post_knit = post_knit,
                                pre_processor = pre_processor,
                                base_format = rmarkdown::html_document(...))
  return(o)
}