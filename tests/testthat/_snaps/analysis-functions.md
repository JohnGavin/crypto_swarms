# compute_window_summary column names snapshot

    Code
      names(result)
    Output
      [1] "token"         "ma_7d"         "median_7d"     "mad_7d"       
      [5] "liq_median_7d" "liq_mad_7d"    "n_liq_7d"      "n_7d"         

# compute_bollinger output structure snapshot

    Code
      str(bb)
    Output
      tibble [2 x 5] (S3: tbl_df/tbl/data.frame)
       $ token      : chr [1:2] "SOL" "USDC"
       $ bb_mid_7d  : num [1:2] 84.393 0.928
       $ bb_upper_7d: num [1:2] 88.65 1.05
       $ bb_lower_7d: num [1:2] 80.138 0.802
       $ bb_valid_7d: logi [1:2] FALSE FALSE

# compute_alerts column names snapshot

    Code
      names(result)
    Output
       [1] "token"                "source"               "price_usd"           
       [4] "price_change_24h"     "liquidity"            "block_id"            
       [7] "fetched_at"           "ma_7d"                "median_7d"           
      [10] "mad_7d"               "liq_median_7d"        "liq_mad_7d"          
      [13] "n_liq_7d"             "n_7d"                 "ma_30d"              
      [16] "median_30d"           "mad_30d"              "liq_median_30d"      
      [19] "liq_mad_30d"          "n_liq_30d"            "n_30d"               
      [22] "bb_mid_7d"            "bb_upper_7d"          "bb_lower_7d"         
      [25] "bb_valid_7d"          "have_robust_history"  "rel_mad_7d"          
      [28] "nontrivial_price_mad" "robust_zscore"        "price_anomaly"       
      [31] "bb_break"             "have_robust_liq"      "rel_liq_mad_7d"      
      [34] "nontrivial_liq_mad"   "liq_zscore"           "liq_drop_pct"        
      [37] "liquidity_alert"      "is_stablecoin"        "depeg_alert"         
      [40] "trigger_alert"       

# regime_rollmad label distribution snapshot

    Code
      table(result$regime_mad, useNA = "ifany")
    Output
      
        high    low medium   <NA> 
          17     19     15     10 

# regime_transitions output snapshot

    Code
      dplyr::select(result, regime_mad, prev_regime, is_transition,
        transition_direction)
    Output
      # A tibble: 4 x 4
        regime_mad prev_regime is_transition transition_direction
        <chr>      <chr>       <lgl>         <chr>               
      1 low        <NA>        FALSE         <NA>                
      2 high       low         TRUE          up                  
      3 high       high        FALSE         <NA>                
      4 low        high        TRUE          down                

# regime_latest snapshot

    Code
      regime_latest(df)
    Output
      # A tibble: 1 x 4
        token regime_mad is_transition transition_direction
        <chr> <chr>      <lgl>         <chr>               
      1 SOL   high       TRUE          up                  

