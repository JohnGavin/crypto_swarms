{
  description = "crypto_alert_t — Crypto price alerts with Python APIs + R analysis";

  inputs = {
    nixpkgs.url = "github:rstats-on-nix/nixpkgs/2026-04-04";
    flake-utils.url = "github:numtide/flake-utils";
    t-lang.url = "github:b-rodrigues/tlang/v0.51.2";
  };

  nixConfig = {
    extra-substituters = [
      "https://rstats-on-nix.cachix.org"
    ];
    extra-trusted-public-keys = [
      "rstats-on-nix.cachix.org-1:vdiiVgocg6WeJrODIqdprZRUrhi1JzhBnXv7aWI6+F0="
    ];
  };

  outputs = { self, nixpkgs, flake-utils, t-lang }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # R environment
        r-env = pkgs.rWrapper.override {
          packages = with pkgs.rPackages; [
            dplyr
            arrow
            slider
            ggplot2
            jsonlite
            knitr
            reticulate
            pointblank
            targets
            crew
            duckplyr
          ];
        };

        # Python environment (httpx for fetch script + pandas/pyarrow/plotly for pipeline)
        py-env = pkgs.python313.withPackages (ps: with ps; [
          httpx
          pandas
          pyarrow
          plotly
        ]);

        # Additional tools
        additionalTools = with pkgs; [
          quarto
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            t-lang.packages.${system}.default
            r-env
            py-env
          ] ++ additionalTools;

          shellHook = ''
            echo "=================================================="
            echo "T Project: crypto_alert_t"
            echo "=================================================="
            echo ""
            echo "Phase 1: Python fetch -> R analyse -> Python alert"
            echo ""
            echo "Commands:"
            echo "  t run src/pipeline.t   - Run the pipeline"
            echo "  t repl                 - Interactive REPL"
            echo ""
            mkdir -p _extensions
            expected_quarto_ext="${t-lang.packages.${system}.default}/share/tlang/quarto/tlang"
            quarto_ext_path="_extensions/tlang"
            quarto_ext_stamp="$quarto_ext_path/.tlang-store-path"
            provision_quarto_ext() {
              rm -rf "$quarto_ext_path"
              mkdir -p "$quarto_ext_path"
              cp -R "$expected_quarto_ext"/. "$quarto_ext_path"/
              printf '%s\n' "$expected_quarto_ext" > "$quarto_ext_stamp"
              echo "Provisioned T Quarto extension at _extensions/tlang"
            }
            if [ -L "$quarto_ext_path" ]; then
              provision_quarto_ext
            elif [ -d "$quarto_ext_path" ] && [ -f "$quarto_ext_stamp" ]; then
              current_quarto_ext="$(cat "$quarto_ext_stamp")"
              if [ "$current_quarto_ext" != "$expected_quarto_ext" ]; then
                provision_quarto_ext
              fi
            elif [ -e "$quarto_ext_path" ]; then
              echo "Quarto extension path _extensions/tlang already exists; leaving it unchanged."
            else
              provision_quarto_ext
            fi
          '';
        };
      }
    );
}
