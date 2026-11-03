{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
let
  pkgs-stable = import inputs.nixpkgs-stable { inherit (pkgs.stdenv) system; };
in
{
  # devenv.sh/packages/
  packages = with pkgs; [
    pkgs-stable.azure-cli # setup-azure.sh (containerapp commands are built in; no extension needed)
    gh # setup-azure.sh --set-gh-secrets
    curl
    docker-client
    docker-buildx
    shellcheck
    actionlint
    # azure-functions-core-tools # Phase 2
  ];

  # devenv.sh/languages/
  languages = {
    javascript = {
      enable = true;
      pnpm.enable = true;
    };
  };

  # Azure resources are created/deleted by ./setup-azure.sh up|down; sign in with `az login` first.

  # See full reference at https://devenv.sh/reference/options/
}
