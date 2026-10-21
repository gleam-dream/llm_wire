{
  description = "Development environment for llm_wire";

  inputs = {
    design-layer.url = "github:lostbean/design-layer/main";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      design-layer,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          settings.global.excludes = [
            "**/*.pdf"
            ".render/**"
            "**/.render/**"
            "build/**"
            "test/fixtures/**"
            "test/cassettes/**"
            "docs/evidence/**"
          ];
          programs.gleam.enable = true;
          programs.nixfmt.enable = true;
          programs.prettier.enable = true;
          programs.ruff-format.enable = true;
          programs.erlfmt.enable = true;
          programs.shfmt.enable = true;
          settings.formatter.shfmt.includes = [
            "*.sh"
            "dev/gate"
            "dev/check-native"
            "dev/record-live"
          ];
        };
      in
      {
        apps.snips = design-layer.apps.${system}.snips;
        apps.design-gate-check = design-layer.apps.${system}.check;
        apps.design-gate-render = design-layer.apps.${system}.render;
        apps.design-gate-context = design-layer.apps.${system}.context;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            git
            lefthook
            gleam
            beam29Packages.erlang
            beam29Packages.rebar3
            python3
            nghttp2
            ripgrep
            ruff
            findutils
            treefmtEval.config.build.wrapper
          ];
        };

        formatter = treefmtEval.config.build.wrapper;

        checks.formatting = treefmtEval.config.build.check ./.;
      }
    );
}
