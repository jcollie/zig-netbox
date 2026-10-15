# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie
# SPDX-License-Identifier: MIT

{
  description = "zig-netbox";
  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";
    };
    # Mine, not the one in nixpkgs, which is Jari Vetoniemi's original and
    # takes different options.
    zon2nix = {
      url = "github:jcollie/zon2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      nixpkgs,
      zon2nix,
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
      packages = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        {
          # The Zig dependencies, fetched by Nix rather than by `zig build`, so
          # that they come through the Nix cache. Handed to Zig with `--system`,
          # plus a `--fork` of each package in `pathDependencyPackages`; see
          # the README.
          # Regenerate with
          #   nix develop -c zon2nix --17 --nix=build.zig.zon.nix build.zig.zon
          zig-deps = pkgs.callPackage ./build.zig.zon.nix { };
        }
      );

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
              pkgs.zig_0_17
              # Wrapped so that the `zig env` it shells out to is this
              # project's Zig rather than whatever happens to be on PATH --
              # without one it prints "unable to execute zig" and writes
              # nothing, leaving the previous build.zig.zon.nix in place
              # looking untouched.
              (pkgs.symlinkJoin {
                name = "zon2nix";
                paths = [ zon2nix.packages.${pkgs.stdenv.hostPlatform.system}.zon2nix ];
                nativeBuildInputs = [ pkgs.makeWrapper ];
                postBuild = ''
                  wrapProgram $out/bin/zon2nix \
                    --prefix PATH : ${lib.makeBinPath [ pkgs.zig_0_17 ]}
                '';
              })
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
