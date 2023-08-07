# This file is part of the IOGX template and is documented at the link below:
# https://www.github.com/input-output-hk/iogx#39-nixcinix

{ pkgs, ... }: 
{
  includedPaths = pkgs.lib.optionals (pkgs.system == "x86_64-linux") [
    "dockerApps"
  ];
}