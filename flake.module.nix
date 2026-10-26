# flake.module.nix — project-specific flake-parts customizations.
#
# seihou does NOT manage this file: it is never regenerated or overwritten by
# `seihou run` or by module migrations, so edits here survive template upgrades
# without conflict. flake.nix imports it automatically when present.
#
# See flake.module.nix.example for the full set of available options.
{ ... }:
{
  perSystem = { pkgs, ... }: {
    # Project-specific dev-shell tools, kept here instead of the managed
    # nix/haskell.nix (reads the option declared there). `xz` was carried over
    # from the pre-adoption hand-written dev shell.
    haskellProject.extraDevPackages = [ pkgs.xz ];
  };
}
