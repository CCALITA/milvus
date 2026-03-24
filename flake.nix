{
  description = "Milvus Linux x86_64 clang + libc++ development shells";

  inputs = {
    # Keep the validated proof shell on the branch that already worked for clang 18.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # Compatibility shell for an older glibc baseline. Stock nixpkgs does not expose
    # llvmPackages_18 on a glibc 2.35 branch, so this shell uses the newest LLVM that
    # exists on nixos-22.11 (llvm 16) while keeping the libc++ runtime on glibc 2.35.
    # Pin explicitly to avoid GitHub branch-resolution API rate limiting during remote flake eval.
    nixpkgsGlibc235.url = "github:NixOS/nixpkgs/ea4c80b39be4c09702b0cb3b42eab59e2ba4f24b";
  };

  outputs = { self, nixpkgs, nixpkgsGlibc235 }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs { inherit system; };
      pkgsGlibc235 = import nixpkgsGlibc235 { inherit system; };

      mkLinuxClangLibcxxShell = {
        pkgs,
        llvmPkgs,
        shellName,
        glibcBaseline ? null,
        extraNotice ? null,
      }:
        let
          lib = pkgs.lib;
          clangMajor = lib.versions.major llvmPkgs.clang.version;
          pythonEnv = pkgs.python311.withPackages (ps: with ps; [
            jinja2
            pip
            setuptools
            wheel
          ]);
          runtimeLibs = [
            llvmPkgs.libcxx
            llvmPkgs.libunwind
            llvmPkgs.openmp
            pkgs.gperftools
            pkgs.libaio
            pkgs.openblas
            pkgs.openssl
            pkgs.stdenv.cc.cc.lib
            pkgs.util-linux
            pkgs.zlib
          ];
          pkgConfigPath = lib.makeSearchPathOutput "dev" "lib/pkgconfig" runtimeLibs;
          runtimeLibPath = lib.makeLibraryPath runtimeLibs;
          glibcLibDir = "${pkgs.glibc.out}/lib";
        in
        pkgs.mkShell {
          stdenv = llvmPkgs.libcxxStdenv;
          packages =
            (with pkgs; [
              autoconf
              automake
              bashInteractive
              cacert
              cargo
              ccache
              cmake
              curl
              gcc
              git
              go
              gfortran
              gnumake
              grpc
              libtool
              m4
              ninja
              perl
              pkgconf
              protobuf
              pythonEnv
              rustc
              rustfmt
              unzip
              which
              zip

              gperftools
              libaio
              openblas
              util-linux

              llvmPkgs.clang
              llvmPkgs.libcxx
              llvmPkgs.libunwind
              llvmPkgs.lld
              llvmPkgs.openmp
            ])
            ++ lib.optional (builtins.hasAttr "clang-tools" llvmPkgs) llvmPkgs."clang-tools"
            ++ lib.optional (builtins.hasAttr "compiler-rt" llvmPkgs) llvmPkgs."compiler-rt";
          shellHook = ''
            export MILVUS_NIX_CLANG_LIBCXX=1
            export MILVUS_USE_CLANG=1
            export MILVUS_CLANG_VERSION=${clangMajor}
            export MILVUS_CLANG_STDLIB=libc++
            ${if glibcBaseline != null then "export MILVUS_GLIBC_BASELINE=${glibcBaseline}" else "unset MILVUS_GLIBC_BASELINE || true"}

            # ConanCenter's azure-sdk-for-cpp/1.11.3 recipe does not currently admit
            # the Linux clang profile used by this shell. Keep the supported Nix
            # clang+libc++ proof path on public dependencies by disabling Azure FS.
            export ENABLE_AZURE_FS=OFF

            export PATH="${pkgs.cmake}/bin:${pkgs.ninja}/bin:${pkgs.pkgconf}/bin:${llvmPkgs.clang}/bin:${llvmPkgs.lld}/bin:${llvmPkgs.llvm}/bin:$PATH"
            if [ -d "$HOME/.local/bin" ]; then
              export PATH="$HOME/.local/bin:$PATH"
            fi
            export CC="${llvmPkgs.clang}/bin/clang"
            export CXX="${llvmPkgs.clang}/bin/clang++"
            export ASM="${llvmPkgs.clang}/bin/clang"
            export PATH="$(dirname "$CC"):$PATH"
            export LD="${llvmPkgs.lld}/bin/ld.lld"
            export AR="${llvmPkgs.llvm}/bin/llvm-ar"
            export NM="${llvmPkgs.llvm}/bin/llvm-nm"
            export RANLIB="${llvmPkgs.llvm}/bin/llvm-ranlib"

            export CMAKE_GENERATOR=Ninja
            export MILVUS_LIBCXX_INCLUDE="${llvmPkgs.libcxx.dev}/include/c++/v1"
            export MILVUS_LIBCXX_LIBDIR="${llvmPkgs.libcxx}/lib"
            export MILVUS_LIBUNWIND_LIBDIR="${llvmPkgs.libunwind}/lib"
            export MILVUS_GLIBC_LIBDIR="${glibcLibDir}"
            export MILVUS_BOOST_B2_CXXFLAGS="-nostdinc++ -isystem $MILVUS_LIBCXX_INCLUDE -stdlib=libc++"
            export MILVUS_BOOST_B2_LINKFLAGS="-L$MILVUS_LIBCXX_LIBDIR -L$MILVUS_LIBUNWIND_LIBDIR -L$MILVUS_GLIBC_LIBDIR -Wl,-rpath,$MILVUS_LIBCXX_LIBDIR -Wl,-rpath,$MILVUS_LIBUNWIND_LIBDIR -Wl,-rpath,$MILVUS_GLIBC_LIBDIR -stdlib=libc++ -fuse-ld=lld"
            export CXXFLAGS="$CXXFLAGS $MILVUS_BOOST_B2_CXXFLAGS"
            export LDFLAGS="$LDFLAGS $MILVUS_BOOST_B2_LINKFLAGS"
            export CGO_CXXFLAGS="$CGO_CXXFLAGS -nostdinc++ -isystem $MILVUS_LIBCXX_INCLUDE -stdlib=libc++"
            export CGO_LDFLAGS="$CGO_LDFLAGS -L$MILVUS_LIBCXX_LIBDIR -L$MILVUS_LIBUNWIND_LIBDIR -L$MILVUS_GLIBC_LIBDIR -Wl,-rpath,$MILVUS_LIBCXX_LIBDIR -Wl,-rpath,$MILVUS_LIBUNWIND_LIBDIR -Wl,-rpath,$MILVUS_GLIBC_LIBDIR -stdlib=libc++ -fuse-ld=lld"
            export CPATH="$MILVUS_LIBCXX_INCLUDE''${CPATH:+:$CPATH}"
            export CPLUS_INCLUDE_PATH="$MILVUS_LIBCXX_INCLUDE''${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"
            export LIBRARY_PATH="$MILVUS_LIBCXX_LIBDIR:$MILVUS_LIBUNWIND_LIBDIR:$MILVUS_GLIBC_LIBDIR''${LIBRARY_PATH:+:$LIBRARY_PATH}"

            # Keep Nix libc++/libunwind discoverable at shell runtime, but do not
            # force the Nix glibc onto LD_LIBRARY_PATH because Milvus still invokes
            # host-provided tools (notably the Conan 1 venv Python) that must run
            # against the host glibc.
            if [ -n "$LD_LIBRARY_PATH" ]; then
              export LD_LIBRARY_PATH="${runtimeLibPath}:$LD_LIBRARY_PATH"
            else
              export LD_LIBRARY_PATH="${runtimeLibPath}"
            fi

            if [ -n "$PKG_CONFIG_PATH" ]; then
              export PKG_CONFIG_PATH="${pkgConfigPath}:$PKG_CONFIG_PATH"
            else
              export PKG_CONFIG_PATH="${pkgConfigPath}"
            fi

            if command -v conan >/dev/null 2>&1; then
              conan_version="$(conan --version 2>/dev/null || true)"
              case "$conan_version" in
                *"Conan version 1."*) ;;
                "") ;;
                *)
                  echo "WARN: Milvus build scripts still expect Conan 1.x; found: $conan_version"
                  ;;
              esac
            else
              echo "NOTE: activate a Conan 1.x environment before running Milvus build scripts."
            fi

            echo "Milvus Linux x86_64 clang+libc++ shell ready (${shellName})."
            ${if glibcBaseline != null then ''echo "glibc baseline target: ${glibcBaseline}"'' else ""}
            ${if extraNotice != null then ''echo "${extraNotice}"'' else ""}
            echo "Build C++ with: make build-cpp"
            echo "Or run: bash scripts/3rdparty_build.sh -t Release && bash scripts/core_build.sh -t Release"
          '';
        };

      proofShell = mkLinuxClangLibcxxShell {
        inherit pkgs;
        llvmPkgs = pkgs.llvmPackages_18;
        shellName = "linux-clang-libcxx";
      };

      compatShellGlibc235 = mkLinuxClangLibcxxShell {
        pkgs = pkgsGlibc235;
        llvmPkgs = pkgsGlibc235.llvmPackages_16;
        shellName = "linux-clang-libcxx-glibc235";
        glibcBaseline = "2.35";
        extraNotice = "Compatibility shell: libc++.so.1 comes from the nixos-22.11 / glibc 2.35 LLVM runtime stack.";
      };
    in {
      devShells.${system} = {
        default = proofShell;
        linux-clang-libcxx = proofShell;
        linux-clang-libcxx-glibc235 = compatShellGlibc235;
      };
    };
}
