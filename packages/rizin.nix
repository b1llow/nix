{
  rizin,
  meson,
  git,
  openssl,
  stdenv,
  keepDebugInfo,
  lib,
  fetchFromGitHub,
  mesonTools,
  rev ? "dd618bb30a3ca7dea2f41d0c3e31d448d3070a1d",
  sha256 ? lib.fakeHash,
  mesonDepsSha256 ? lib.fakeHash,
  debug ? false,
  buildType ? if debug then "debug" else "release",
  ...
}:
let
  inherit (builtins) filter baseNameOf;

  src = fetchFromGitHub {
    owner = "rizinorg";
    repo = "rizin";
    inherit rev sha256;
  };
  mesonDeps = mesonTools.fetchDeps {
    pname = "rizin";
    inherit src;
    sha256 = mesonDepsSha256;
  };
  usePlugins = (
    rz:
    (lib.mapAttrs (
      name: prev:
      (prev.override { rizin = rz; }).overrideAttrs (prev': {
        postFixup = (prev'.postInstall or "") + ''
          set -euo pipefail

          plugdir="$out/lib/rizin/plugins"
          stdlib="$out/lib"
          mkdir -p "$stdlib"

          cd $plugdir
          for l in *.dylib; do
            ln -s "$plugdir/$l" "$stdlib/$l"
          done
        '';
      })
    ) (lib.filterAttrs (k: v: k != "sigdb") rizin.plugins))
    // {
      sigdb = rizin.plugins.sigdb;
    }
  );
  debugAndDarwin = debug && stdenv.isDarwin;
  rizin' = (
    (rizin.override { stdenv = if debugAndDarwin then keepDebugInfo stdenv else stdenv; }).overrideAttrs
      (
        finalAttrs: prevAttrs:
        (
          {
            pname = "rizin";
            version = "0.9.0.${src.rev}";
            inherit src mesonDeps;
            patches = filter (x: baseNameOf x != "0001-fix-compilation-with-clang.patch") prevAttrs.patches;

            separateDebugInfo = debug;
            mesonBuildType = buildType;

            mesonFlags = [ "-Dportable=true" ];
            nativeBuildInputs = (prevAttrs.nativeBuildInputs or [ ]) ++ [
              mesonTools.configHook
            ];
            buildInputs = [ ];

            passthru = rec {
              plugins = usePlugins rizin';
              withPlugins =
                filter:
                ((rizin.withPlugins filter).override {
                  rizin = rizin';
                  plugins = filter plugins;
                });
            };
          }
          // lib.optionalAttrs debugAndDarwin {
            dontStrip = true;
            outputs =
              (prevAttrs.outputs or [
                "out"
              ]
              )
              ++ [ "debug" ];
            preConfigure = (prevAttrs.preConfigure or "") + ''
              echo "source root: $PWD"
              compdir=${finalAttrs.pname}
              export NIX_CFLAGS_COMPILE+=" \
                          -fdebug-prefix-map=$PWD=/$compdir \
                          -ffile-prefix-map=$PWD=/$compdir \
                          -fdebug-compilation-dir=/$compdir/build"
            '';
            postInstall = (prevAttrs.postInstall or "") + ''
              set -euo pipefail
              mkdir -p $debug/bin $debug/lib
              shopt -s nullglob
              mkdir -p $debug/.uuids

              mk_dsym() {
                local bin="$1"
                local outdir="$2"
                local uuid="$(dwarfdump --uuid "$bin" | sed -n 's/.*UUID: \([0-9A-F-]*\).*/\1/p' | head -n1)"
                local canon="$debug/.store/$uuid.dSYM"
                local base="$(basename "$bin")"
                local bindsym="$outdir/$base.dSYM"
                local dwarf="$canon/Contents/Resources/DWARF/$base"

                if [ -f "$canon" ]; then
                  ln -sfn "$canon" "$bindsym"
                else
                  dsymutil "$bin" -o "$canon"
                  ln -sfn "$canon" "$bindsym"

                  hex="''${uuid//-/}"
                  dir="$debug/uuidmap/''${hex:0:4}/''${hex:4:4}/''${hex:8:4}/''${hex:12:4}/''${hex:16:4}"
                  mkdir -p "$dir"
                  dwarf_uuid="$dir/''${hex:20:12}"
                  ln -sfn "$dwarf" "$dwarf_uuid"
                  echo "$bindsym: $dwarf_uuid -> $dwarf"
                fi
              }

              for f in $out/bin/* $out/lib/*.dylib; do
                [ -f "$f" ] || continue
                mk_dsym "$f" "$debug/$(basename $(dirname "$f"))"
              done

              strip -Sx $out/bin/* $out/lib/*.dylib || true
            '';

          }
        )
      )
  );
in
rizin'
