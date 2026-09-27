# progression_ladder_status output snapshot

    Code
      dplyr::select(result, step, phase, status, source)
    Output
      # A tibble: 8 x 4
         step phase                             status        source                  
        <int> <chr>                             <chr>         <chr>                   
      1     1 Perp yield                        INDETERMINATE Hyperliquid funding rat~
      2     2 On-chain stocks                   INDETERMINATE RWA / tokenized-equity ~
      3     3 Private trading                   INDETERMINATE No candidate data sourc~
      4     4 Institutional lending             INDETERMINATE No candidate data sourc~
      5     5 Direct issuance                   INDETERMINATE RWA / tokenized-equity ~
      6     6 CBDC corporate finance            INDETERMINATE No candidate data sourc~
      7     7 Private FX swaps                  INDETERMINATE Non-USD stablecoin + FX~
      8     8 Looped international fixed income INDETERMINATE Cross-border tokenized ~

# indicator descriptions snapshot

    Code
      result$indicator
    Output
      [1] "Funding-rate level/trend on Hyperliquid-style perps for equity-like/index proxies"    
      [2] "Price-vs-underlying peg/premium and liquidity for tokenized-equity instruments (G3)"  
      [3] "Volume or venue-share data for permissioned/private on-chain trading venues"          
      [4] "TVL or origination volume for institutional on-chain lending desks"                   
      [5] "Count/value of new direct on-chain corporate debt or equity issuance events"          
      [6] "Any CBDC-denominated corporate-finance activity (issuance, settlement volume)"        
      [7] "Volume of privately-negotiated on-chain FX swaps referencing non-USD stablecoins (G5)"
      [8] "Cross-border tokenized fixed-income positions referencing each other (looping)"       

