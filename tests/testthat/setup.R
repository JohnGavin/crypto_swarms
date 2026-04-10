# Non-package project: enable testthat edition 3 for snapshot support
testthat::local_edition(3, .env = testthat::teardown_env())
