{
  # Fork-local dev shell (mutech/nats.py). Not part of upstream nats-io/nats.py.
  #
  # Tool versions are read from the files CI reads, so the shell cannot drift
  # from CI silently: uv from .github/workflows/check.yml (setup-uv `version:`),
  # ruff and ty from uv.lock (CI runs them via `uv run --no-sync`). A version
  # bump there fails evaluation here until its hash is added to `hashes` below.
  #
  # PyPI's manylinux ruff/ty wheels are dynamic ELF executables that do not run
  # on NixOS (no nix-ld), so the shell provides astral's static musl builds of
  # the same versions; run `ruff` / `ty` directly, not through `uv run`.
  description = "nats.py (snats fork) dev shell, tool versions pinned to CI";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;

      lines = file: lib.splitString "\n" (builtins.readFile file);

      # First capture of `re` over the lines of `file`; evaluation error if absent.
      grab = file: re:
        let hits = lib.filter (m: m != null) (map (builtins.match re) (lines file));
        in if hits == [ ] then throw "flake.nix: no match for ${re} in ${toString file}"
           else builtins.head (builtins.head hits);

      # uv.lock: `name = "<pkg>"` is followed directly by `version = "<v>"`.
      lockVersion = pkg:
        let
          ls = lines ./uv.lock;
          idx = lib.lists.findFirstIndex (l: l == ''name = "${pkg}"'') null ls;
        in if idx == null then throw "flake.nix: ${pkg} not in uv.lock"
           else builtins.head (builtins.match ''version = "([^"]+)"'' (builtins.elemAt ls (idx + 1)));

      versions = {
        uv = grab ./.github/workflows/check.yml ''[[:space:]]+version: "([^"]+)"[[:space:]]*'';
        ruff = lockVersion "ruff";
        ty = lockVersion "ty";
      };

      # x86_64-unknown-linux-musl release tarballs, keyed by tool and version.
      hashes = {
        uv."0.12.2" = "sha256-Lb6CCclZL20QCbhWX0vymBNCeQe+4iNgI8ATEB7eND8=";
        ruff."0.14.10" = "sha256-4frG8nBQV/SPPQAGlND0HJWwbnOM9IJTFcZw87nSSTM=";
        ty."0.0.15" = "sha256-27cVzvWzjzu9DZLJsOr6oB2c3U6h4RNOWMdR0J9flAQ=";
      };

      astral = name:
        let
          version = versions.${name};
          url = "https://github.com/astral-sh/${name}/releases/download/${version}/${name}-x86_64-unknown-linux-musl.tar.gz";
        in pkgs.stdenvNoCC.mkDerivation {
          pname = name;
          inherit version;
          src = pkgs.fetchurl {
            inherit url;
            hash = hashes.${name}.${version} or (throw ''
              flake.nix: CI pins ${name} ${version}; add its hash to `hashes`:
                nix hash convert --hash-algo sha256 --to sri $(nix-prefetch-url ${url})'');
          };
          sourceRoot = ".";
          installPhase = ''find . -type f -perm -u+x -exec install -Dm755 -t $out/bin {} +'';
        };

      # CI: legacy client matrix 3.8-3.13, checks and modern packages on 3.13.
      # nixpkgs carries 3.11+; 3.13 is the default interpreter.
      python = pkgs.python313;

      # CI builds mutech/nats-server@main from source (no releases for the UDS
      # fork). Locally a sibling checkout (the system-nats superproject layout)
      # wins, so unpushed server changes are what the client is tested against.
      buildNatsServerFork = pkgs.writeShellApplication {
        name = "build-nats-server-fork";
        runtimeInputs = [ pkgs.go pkgs.git ];
        text = ''
          root="$(git rev-parse --show-toplevel)"
          src="''${1:-''${NATS_SERVER_FORK_DIR:-}}"
          if [ -z "$src" ] && [ -e "$root/../nats-server/.git" ]; then
            src="$root/../nats-server"
          fi
          if [ -z "$src" ]; then
            src="''${XDG_CACHE_HOME:-$HOME/.cache}/nats-fork-devshell/nats-server-src"
            if [ -d "$src/.git" ]; then
              git -C "$src" pull -q --ff-only
            else
              git clone -q --depth 1 --branch main https://github.com/mutech/nats-server.git "$src"
            fi
          fi
          echo "building nats-server from $src ($(git -C "$src" rev-parse --short HEAD))"
          go -C "$src" build -o "$root/.devshell/bin/nats-server" .
          "$root/.devshell/bin/nats-server" --version
        '';
      };
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          python
          pkgs.python312
          pkgs.python311
          (astral "uv")
          (astral "ruff")
          (astral "ty")
          pkgs.go
          pkgs.git
          buildNatsServerFork
        ];

        shellHook = ''
          root="$(git rev-parse --show-toplevel)"
          export PATH="$root/.devshell/bin:$PATH"
          # Nix interpreters only: uv-managed CPython builds do not run on NixOS.
          export UV_PYTHON_DOWNLOADS=never
          export UV_PYTHON="${python}/bin/python3"
          # Go state for the fork server build: out of the tree (codespell, ruff
          # and pytest walk it) and out of ~/go; shared by the fork dev shells.
          cache="''${XDG_CACHE_HOME:-$HOME/.cache}/nats-fork-devshell"
          export GOPATH="$cache/go"
          export GOMODCACHE="$cache/go/pkg/mod"
          export GOCACHE="$cache/go-build"
          echo "nats.py dev shell: uv ${versions.uv}, ruff ${versions.ruff}, ty ${versions.ty}, ${python.name}"
          # A stock nats-server elsewhere on PATH lacks UDS; require the fork build.
          [ -x "$root/.devshell/bin/nats-server" ] \
            || echo "  no fork nats-server in .devshell/bin: run build-nats-server-fork"
        '';
      };
    };
}
