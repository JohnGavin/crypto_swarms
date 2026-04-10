#!/usr/bin/env Rscript
# Run all tests. Usage: NOT_CRAN=true Rscript tests/run_tests.R
source("R/analysis_functions.R")
testthat::test_dir("tests/testthat", reporter = "summary")
