# regime_changepoint output shape

    Code
      names(regime_changepoint(hist, min_obs = 30))
    Output
      [1] "token"      "fetched_at" "regime_cpt"

# regime_changepoint label distribution snapshot on a known break

    Code
      table(result$regime_cpt, useNA = "ifany")
    Output
      
      high  low <NA> 
        58   62    1 

# regime_consensus disagreement full output snapshot

    Code
      dplyr::select(result, token, regime_consensus, regime_confidence)
    Output
      # A tibble: 1 x 3
        token regime_consensus regime_confidence
        <chr> <chr>                        <dbl>
      1 SOL   high                           0.5

# regime_consensus full output snapshot

    Code
      dplyr::select(result, token, regime_consensus, regime_confidence)
    Output
      # A tibble: 2 x 3
        token regime_consensus regime_confidence
        <chr> <chr>                        <dbl>
      1 SOL   high                           1  
      2 JUP   low                            0.5

