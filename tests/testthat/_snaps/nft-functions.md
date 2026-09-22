# compute_nft_window_summary output shape

    Code
      names(compute_nft_window_summary(hist))
    Output
      [1] "collection"       "floor_median_14d" "floor_mad_14d"    "n_14d"           

# compute_nft_alerts full output for a flagged drop

    Code
      print(result)
    Output
      # A tibble: 1 x 5
        collection floor_sol floor_median_14d n_14d floor_drop_alert
        <chr>          <dbl>            <dbl> <int> <lgl>           
      1 TestCol            5               10    13 TRUE            

