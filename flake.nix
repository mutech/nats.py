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

      # CI builds the UDS server fork from source at the commit pinned in
      # .github/workflows/test.yml (NATS_SERVER_FORK_REPO/REF), with Go `stable`.
      # build-nats-server-fork reads that pin and builds exactly it, so local runs
      # test against the same server as CI. Building a local checkout instead (the
      # integration step of an upstream sync, before the pin is bumped) must be
      # explicit: `build-nats-server-fork DIR` or NATS_SERVER_FORK_DIR=DIR.
      # The built ref is recorded next to the binary; the shellHook warns when it
      # no longer matches the pin.
      goLatest =
        let names = lib.filter (n: builtins.match "go_1_[0-9]+" n != null) (builtins.attrNames pkgs);
            minor = n: lib.toInt (lib.removePrefix "go_1_" n);
        in pkgs.${lib.last (lib.sort (a: b: minor a < minor b)
             (lib.filter (n: (builtins.tryEval pkgs.${n}).success) names))};

      buildNatsServerFork = pkgs.writeShellApplication {
        name = "build-nats-server-fork";
        runtimeInputs = [ goLatest pkgs.git pkgs.gnugrep pkgs.gnused ];
        text = ''
          root="$(git rev-parse --show-toplevel)"
          ci="$root/.github/workflows/test.yml"
          ci_var() { sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)$/\1/p" "$ci" | head -n1; }
          repo="$(ci_var NATS_SERVER_FORK_REPO)"; ref="$(ci_var NATS_SERVER_FORK_REF)"
          out="$root/.devshell/bin"; mkdir -p "$out"
          src="''${1:-''${NATS_SERVER_FORK_DIR:-}}"
          if [ -n "$src" ]; then
            built="local:$(cd "$src" && pwd)@$(git -C "$src" rev-parse HEAD)$(git -C "$src" diff --quiet || echo +dirty)"
          else
            src="''${XDG_CACHE_HOME:-$HOME/.cache}/nats-fork-devshell/nats-server-src"
            [ -d "$src/.git" ] || git clone -q --filter=blob:none "$repo" "$src"
            git -C "$src" cat-file -e "$ref^{commit}" 2>/dev/null || git -C "$src" fetch -q origin
            git -C "$src" checkout -q --detach "$ref"
            built="$ref"
          fi
          echo "building nats-server: $built"
          go -C "$src" build -o "$out/nats-server" .
          echo "$built" > "$out/nats-server.ref"
          "$out/nats-server" --version
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
          goLatest
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
          # A stock nats-server elsewhere on PATH lacks UDS; require the fork build,
          # at the commit CI pins.
          pin="$(sed -n 's/^[[:space:]]*NATS_SERVER_FORK_REF:[[:space:]]*//p' .github/workflows/test.yml | head -n1)"
          if [ ! -x "$root/.devshell/bin/nats-server" ]; then
            echo "  no fork nats-server in .devshell/bin: run build-nats-server-fork"
          elif [ "$(cat "$root/.devshell/bin/nats-server.ref" 2>/dev/null)" != "$pin" ]; then
            echo "  NOTE: .devshell/bin/nats-server is $(cat "$root/.devshell/bin/nats-server.ref" 2>/dev/null || echo unknown), CI pins $pin"
          fi
        '';
      };
    };
}
