{
  description = "Milvus Linux x86_64 clang + libc++ development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;
      llvmPkgs = pkgs.llvmPackages_18;
      pythonEnv = pkgs.python311.withPackages (ps: with ps; [
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
      shell = pkgs.mkShell {
        stdenv = llvmPkgs.libcxxStdenv;
        packages = with pkgs; [
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
          ninja
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
          llvmPkgs."clang-tools"
          llvmPkgs."compiler-rt"
          llvmPkgs.libcxx
          llvmPkgs.libunwind
          llvmPkgs.lld
          llvmPkgs.openmp
        ];
        shellHook = ''
          export MILVUS_NIX_CLANG_LIBCXX=1
          export MILVUS_USE_CLANG=1
          export MILVUS_CLANG_VERSION=18
          export MILVUS_CLANG_STDLIB=libc++

          # ConanCenter's azure-sdk-for-cpp/1.11.3 recipe does not currently admit
          # the Linux clang profile used by this shell. Keep the supported Nix
          # clang+libc++ proof path on public dependencies by disabling Azure FS.
          export ENABLE_AZURE_FS=OFF
          export ENABLE_AZURE_FS=OFF

          export PATH="${llvmPkgs.clang}/bin:${llvmPkgs.lld}/bin:${llvmPkgs.llvm}/bin:$PATH"
          export CC="${llvmPkgs.clang}/bin/clang"
          export CXX="${llvmPkgs.clang}/bin/clang++"
          export ASM="${llvmPkgs.clang}/bin/clang"
          export LD="${llvmPkgs.lld}/bin/ld.lld"
          export AR="${llvmPkgs.llvm}/bin/llvm-ar"
          export NM="${llvmPkgs.llvm}/bin/llvm-nm"
          export RANLIB="${llvmPkgs.llvm}/bin/llvm-ranlib"

          export CMAKE_GENERATOR=Ninja
          export MILVUS_LIBCXX_INCLUDE="${llvmPkgs.libcxx.dev}/include/c++/v1"
          export MILVUS_LIBCXX_LIBDIR="${llvmPkgs.libcxx}/lib"
          export MILVUS_LIBUNWIND_LIBDIR="${llvmPkgs.libunwind}/lib"
          export CXXFLAGS="$CXXFLAGS -nostdinc++ -isystem $MILVUS_LIBCXX_INCLUDE -stdlib=libc++"
          export LDFLAGS="$LDFLAGS -L$MILVUS_LIBCXX_LIBDIR -L$MILVUS_LIBUNWIND_LIBDIR -Wl,-rpath,$MILVUS_LIBCXX_LIBDIR -Wl,-rpath,$MILVUS_LIBUNWIND_LIBDIR -stdlib=libc++ -fuse-ld=lld"
          export CGO_CXXFLAGS="$CGO_CXXFLAGS -nostdinc++ -isystem $MILVUS_LIBCXX_INCLUDE -stdlib=libc++"
          export CGO_LDFLAGS="$CGO_LDFLAGS -L$MILVUS_LIBCXX_LIBDIR -L$MILVUS_LIBUNWIND_LIBDIR -Wl,-rpath,$MILVUS_LIBCXX_LIBDIR -Wl,-rpath,$MILVUS_LIBUNWIND_LIBDIR -stdlib=libc++ -fuse-ld=lld"

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
              "")
                ;;
              *)
                echo "WARN: Milvus build scripts still expect Conan 1.x; found: $conan_version"
                ;;
            esac
          else
            echo "NOTE: activate a Conan 1.x environment before running Milvus build scripts."
          fi

          echo "Milvus Linux x86_64 clang+libc++ shell ready."
          echo "Build C++ with: make build-cpp"
          echo "Or run: bash scripts/3rdparty_build.sh -t Release && bash scripts/core_build.sh -t Release"
        '';
      };
    in {
      devShells.${system} = {
        default = shell;
        linux-clang-libcxx = shell;
      };
    };
}
