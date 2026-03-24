#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
  # shellcheck disable=SC1090
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
export http_proxy=http://127.0.0.1:18123
export https_proxy=http://127.0.0.1:18123
export HTTP_PROXY=http://127.0.0.1:18123
export HTTPS_PROXY=http://127.0.0.1:18123
export no_proxy=127.0.0.1,localhost
export NO_PROXY=127.0.0.1,localhost
export NIX_CONFIG='experimental-features = nix-command flakes'
export MILVUS_NIX_STORE_ROOT=${MILVUS_NIX_STORE_ROOT:-/export/nix-alt}
export MILVUS_NIX_STORE_URL=${MILVUS_NIX_STORE_URL:-local?root=${MILVUS_NIX_STORE_ROOT}}
export CONAN_USER_HOME=/export/conan-home/milvus
export CONAN_HOME=/export/.cache/conan
export XDG_CACHE_HOME=/export/.cache
export TMPDIR=/export/tmp
mkdir -p /export/tmp /export/build-logs /export/.cache/conan /export/conan-home/milvus "${MILVUS_NIX_STORE_ROOT}"
source /export/venvs/milvus-conan1/bin/activate
export PATH="/export/venvs/milvus-conan1/bin:$PATH"
# Keep the outer Nix CLI isolated from any host/virtualenv loader pollution. The inner
# proof shell will re-establish only the paths it needs.
unset LD_LIBRARY_PATH || true
unset LD_PRELOAD || true
env -u LD_LIBRARY_PATH -u LD_PRELOAD nix --store "${MILVUS_NIX_STORE_URL}" develop .#linux-clang-libcxx --command bash -c '
  export PATH="/export/venvs/milvus-conan1/bin:$PATH"
  hash -r
  set -euo pipefail
  echo ==toolchain==
  echo CC=$CC
  echo CXX=$CXX
  "$CC" --version | head -n1
  "$CXX" --version | head -n1
  echo ==conan==
  conan --version
  echo CONAN_USER_HOME=$CONAN_USER_HOME
  echo ==start-3rdparty==
  bash scripts/3rdparty_build.sh -t Release
  echo ==start-core==
  jobs=${jobs:-64} bash scripts/core_build.sh -t Release
  echo ==artifacts==
  find cmake_build internal/core/output -maxdepth 3 \( -type f -o -type l \) | sed -n "1,120p"
'
