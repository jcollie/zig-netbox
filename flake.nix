# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie
# SPDX-License-Identifier: MIT

{
  description = "zig-netbox";
  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";
    };
  };
  outputs =
    {
      nixpkgs,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      linuxSystems = builtins.filter (
        system: (lib.systems.elaborate system).isLinux
      ) lib.systems.flakeExposed;
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = lib.genAttrs linuxSystems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        {
          default = pkgs.mkShell {
            name = "zig-netbox";
            nativeBuildInputs = [
              pkgs.git-pages-cli
              pkgs.reuse
              pkgs.zig_0_16
            ];
            # The Forgejo runner has no system CA bundle, and a dev shell does
            # not provide one on its own, so Zig's TLS init fails when it
            # fetches dependencies. Point it at cacert explicitly. This has to
            # go in shellHook rather than a plain attribute, because `nix
            # develop` strips SSL_CERT_FILE from the derivation environment.
            shellHook = ''
              export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            '';
          };
        }
      );
    };
}
