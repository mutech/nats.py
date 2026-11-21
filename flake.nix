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

      # uv: CI's setup-uv `version:` if check.yml pins one; otherwise CI uses the latest
      # uv, and so do we (nixpkgs' uv, announced at shell start).
      uvPin =
        let hits = lib.filter (m: m != null)
          (map (builtins.match ''[[:space:]]+version: "([^"]+)"[[:space:]]*'')
            (lines ./.github/workflows/check.yml));
        in if hits == [ ] then null else builtins.head (builtins.head hits);

      versions = {
        uv = if uvPin == null then pkgs.uv.version else uvPin;
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

      rerereTrain = pkgs.writeShellScriptBin "rerere-train" ''
        exec ${pkgs.bash}/bin/bash ${pkgs.git}/share/git/contrib/rerere-train.sh "$@"
      '';

      # commit-msg gate, the same check in every snats repository: rejects messages
      # naming "claude"/"anthropic" (case-insensitive) or carrying a "co-authored-by"
      # line. Fails closed: anything but a clean grep miss rejects. The shellHook
      # installs a copy, not a link: git silently skips a dangling hook symlink after
      # a GC, while a copy whose interpreter is gone makes the commit fail.
      noAttribution = pkgs.writeShellScriptBin "no-attribution" ''
        set -u
        msg="''${1:-}"
        [ -f "$msg" ] || { echo "no-attribution: no commit message file" >&2; exit 1; }
        rc=0; ${pkgs.gnugrep}/bin/grep -iqE 'claude|anthropic|co-authored-by' "$msg" || rc=$?
        [ "$rc" -eq 1 ] && exit 0
        echo "REJECTED: attempt to steal intellectual property or place unsolicited advertizing detected"
        exit 1
      '';

      # QA runner mirroring check.yml and test.yml. Every target's full output goes
      # to its own log, wall time and exit code to summary.tsv and to the
      # cross-session timings file. No timeouts. All targets run even if one fails.
      # ruff/ty run from the shell (static builds), not via `uv run` as in CI.
      # Python 3.8-3.10 of CI's legacy matrix are not in nixpkgs: CI-only.
      #   qa fast   server pin, format, lint, spell, type, legacy client + UDS tests (3.13)
      #   qa full   + package builds, legacy suite on 3.11/3.12/3.13, the 4 project suites
      qa = pkgs.writeShellApplication {
        name = "qa";
        excludeShellChecks = [ "SC2329" ]; # targets are dispatched via "t_$name"
        runtimeInputs = [ pkgs.coreutils pkgs.gnused pkgs.git ];
        text = ''
          root="$(git rev-parse --show-toplevel)"
          cd "$root"
          export PATH="$root/.devshell/bin:$PATH"
          pin="$(sed -n 's/^[[:space:]]*NATS_SERVER_FORK_REF:[[:space:]]*//p' .github/workflows/test.yml | head -n1)"

          # Tests must run against the server CI pins; rebuild it if needed.
          t_server() {
            [ "$(cat .devshell/bin/nats-server.ref 2>/dev/null)" = "$pin" ] || build-nats-server-fork
            nats-server --version; cat .devshell/bin/nats-server.ref
          }
          t_format() { ruff format --check; }
          t_lint()   { ruff check; }
          t_spell()  { uv sync --dev; uv run --no-sync codespell; }
          t_type()   { uv sync --dev; ty check nats-core nats-server; }
          # venvs and dists live outside the tree (codespell and pytest walk it).
          cache="''${XDG_CACHE_HOME:-$HOME/.cache}/nats-fork-devshell/nats.py"
          t_build()  { for p in nats-py nats-core nats-server nats-jetstream nats-key-value; do uv build --package "$p" --out-dir "$cache/dist" || return 1; done; }
          # As CI's legacy job: own venv outside the workspace per Python version.
          legacy() {
            local py="$1" venv; shift; venv="$cache/venv-$(basename "$py")"
            uv venv --no-project --clear --python "$py" "$venv"
            uv pip install --python "$venv/bin/python" --editable ./nats --group ./nats/pyproject.toml:dev
            "$venv/bin/python" -m pytest -x -vv -s --continue-on-collection-errors "$@"
          }
          t_legacy_fast() { legacy ${python}/bin/python3 ./nats/tests/test_client_uds.py ./nats/tests/test_client.py; }
          t_legacy_3_13() { legacy ${pkgs.python313}/bin/python3.13 ./nats/tests; }
          t_legacy_3_12() { legacy ${pkgs.python312}/bin/python3.12 ./nats/tests; }
          t_legacy_3_11() { legacy ${pkgs.python311}/bin/python3.11 ./nats/tests; }
          # Hosts without a usable IPv6 loopback (disable_ipv6) cannot run the tests
          # that bind real IPv6 sockets. Deselect exactly those (by node id, so IPv6
          # tests that need no socket still run), say so, and leave them to CI.
          ipv6_ok() { python3 -c 'import socket; socket.socket(socket.AF_INET6).bind(("::1", 0))' 2>/dev/null; }
          ipv6_socket_tests=(
            nats-server:tests/test_server.py::test_run_with_ipv6_host
            nats-server:tests/test_server.py::test_run_with_ipv6_any_address
            nats-core:tests/test_client.py::test_reconnect_with_ipv6_address
          )
          deselect_for() {
            ipv6_ok && return 0
            local t
            for t in "''${ipv6_socket_tests[@]}"; do
              [ "''${t%%:*}" = "$1" ] || continue
              echo "ENV: no IPv6 loopback on this host; deselecting ''${t#*:} (CI-only)" >&2
              printf '%s\n' "--deselect" "''${t#*:}"
            done
          }
          project() {
            local args; mapfile -t args < <(deselect_for "$1")
            (cd "$1" && uv sync --dev && uv run --no-sync pytest -v -n auto "''${args[@]}")
          }
          t_project_nats_server()    { project nats-server; }
          t_project_nats_core()      { project nats-core; }
          t_project_nats_jetstream() { project nats-jetstream; }
          t_project_nats_key_value() { project nats-key-value; }

          fast_targets="server format lint spell type legacy_fast"
          full_targets="server format lint spell type build legacy_3_13 legacy_3_12 legacy_3_11 project_nats_server project_nats_core project_nats_jetstream project_nats_key_value"

          stage="''${1:-}"; shift || true
          case "$stage" in
            fast) targets="''${*:-$fast_targets}" ;;
            full) targets="''${*:-$full_targets}" ;;
            list) echo "fast: $fast_targets"; echo "full: $full_targets"; exit 0 ;;
            *) echo "usage: qa fast|full|list [TARGET...]" >&2; exit 2 ;;
          esac

          rev="$(git rev-parse --short HEAD)$(git diff --quiet || echo +dirty)"
          # Logs and timings live outside the tree (linters such as codespell walk
          # it), next to each other under the upstream-sync state dir.
          state="''${XDG_STATE_HOME:-$HOME/.local/state}/snats-upstream-sync"
          dir="$state/qa/nats.py/$(date -u +%Y%m%dT%H%M%SZ)-$stage"
          timings="$state/timings.tsv"
          mkdir -p "$dir" "$(dirname "$timings")"
          [ -s "$timings" ] || printf 'date\trepo\trev\tstage\ttarget\tseconds\trc\thost\n' > "$timings"
          echo "qa $stage @ $rev (server pin ''${pin:0:9}) -> $dir"
          failed=0
          for t in $targets; do
            start=$(date +%s); set +e
            ( set -x; "t_$t" ) > "$dir/$t.log" 2>&1; rc=$?
            set -e; secs=$(( $(date +%s) - start ))
            printf '%s\t%s\t%s\n' "$t" "$secs" "$rc" >> "$dir/summary.tsv"
            printf '%s\tnats.py\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$rev" "$stage" "$t" "$secs" "$rc" "$(hostname)" >> "$timings"
            printf '  %-28s rc=%-3s %6ss\n' "$t" "$rc" "$secs"
            [ "$rc" -eq 0 ] || failed=1
          done
          echo "logs: $dir"
          exit "$failed"
        '';
      };
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          python
          pkgs.python312
          pkgs.python311
          (if uvPin == null then pkgs.uv else astral "uv")
          (astral "ruff")
          (astral "ty")
          goLatest
          pkgs.git
          buildNatsServerFork
         
          rerereTrain
          qa
        ];

        shellHook = ''
          # Install the commit gate into this repository only, not into a
          # superproject this shell was started from (`nix develop <path>`).
          top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
          if [ -n "$top" ] && cmp -s "$top/flake.nix" ${./flake.nix}; then
            hooks="$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)/hooks-no-attribution"
            mkdir -p "$hooks"
            install -m 0755 ${noAttribution}/bin/no-attribution "$hooks/commit-msg"
            git -C "$top" config core.hooksPath "$hooks"
          fi
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
          echo "nats.py dev shell: uv ${versions.uv}${lib.optionalString (uvPin == null) " (CI does not pin uv; using nixpkgs uv)"}, ruff ${versions.ruff}, ty ${versions.ty}, ${python.name}"
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
