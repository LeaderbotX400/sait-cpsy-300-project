{
  pkgs,
  lib,
  config,
  ...
}:
{
  # devenv.sh/packages/
  packages = with pkgs; [
    azure-cli
    azure-functions-core-tools
  ];

  # devenv.sh/languages/
  languages = {
    javascript = {
      enable = true;
      pnpm.enable = true;
    }
  };

  # Azure uses the azurerm provider from the project's Terraform configuration.
  # Authenticate with `az login` or the service-principal environment variables
  # expected by the AzureRM provider.

  # See full reference at https://devenv.sh/reference/options/
}
