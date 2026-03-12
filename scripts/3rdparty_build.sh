#!/usr/bin/env bash

# Licensed to the LF AI & Data foundation under one
# or more contributor license agreements. See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership. The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Skip the installation and compilation of third-party code, 
# if the developer is certain that it has already been done.
if [[ ${SKIP_3RDPARTY} -eq 1 ]]; then
  exit 0
fi

set -eo pipefail

# Speed up builds (Conan/CMake/Make parallelism)
export CONAN_CPU_COUNT="${CONAN_CPU_COUNT:-$(nproc)}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}"
export MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"

usage() {
  echo "Usage: $0 [-o BUILD_OPENDAL] [-t BUILD_TYPE] [-h]"
  echo "  -o BUILD_OPENDAL  Enable/disable OpenDAL build (ON/OFF, default: OFF)"
  echo "  -t BUILD_TYPE     Set build type (Debug/Release/RelWithDebInfo/MinSizeRel, default: Release)"
  echo "  -h                Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0                          # Build with default settings (Release, OpenDAL OFF)"
  echo "  $0 -t Debug                 # Build in Debug mode"
  echo "  $0 -o ON -t RelWithDebInfo  # Build with OpenDAL enabled and RelWithDebInfo"
}

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done

BUILD_OPENDAL="OFF"
BUILD_TYPE="Release"
while getopts "o:t:h" arg; do
  case $arg in
  o)
    BUILD_OPENDAL=$OPTARG
    ;;
  t)
    BUILD_TYPE=$OPTARG
    ;;
  h)
    usage
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
 esac
done

# Validate build type
case "${BUILD_TYPE}" in
  Debug|Release)
    echo "Build type: ${BUILD_TYPE}"
    ;;
  *)
    echo "Invalid build type: ${BUILD_TYPE}. Valid options are: Debug, Release"
    exit 1
    ;;
esac

ROOT_DIR="$( cd -P "$( dirname "$SOURCE" )/.." && pwd )"
CPP_SRC_DIR="${ROOT_DIR}/internal/core"
BUILD_OUTPUT_DIR="${ROOT_DIR}/cmake_build"

if [[ ! -d ${BUILD_OUTPUT_DIR} ]]; then
  mkdir ${BUILD_OUTPUT_DIR}
fi

source ${ROOT_DIR}/scripts/setenv.sh

# Prefer an already-active Conan in PATH (e.g. from a venv). Only fall back to ~/.local/bin.
if ! command -v conan >/dev/null 2>&1 && [[ -f "$HOME/.local/bin/conan" ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

# Under the Nix clang+libc++ shell we intentionally expose Nix runtime libraries via
# LD_LIBRARY_PATH for the build, but Conan 1.x commonly resolves to /usr/bin/python3.
# If that Python picks up Nix's OpenSSL/libcrypto on an older host glibc, HTTPS fetches
# fail with missing GLIBC symbols and Conan can no longer talk to ConanCenter.
# We still scrub loader vars for Conan itself, but keep the Nix cmake on PATH by default:
# when Conan builds source packages (for example grpc) against Nix-built shared OpenSSL on
# an older host glibc, `/usr/bin/cmake` can fail to load the package libcrypto.so with
# `GLIBC_2.38 not found`, while the Nix-shell cmake succeeds inside the same libc/OpenSSL
# world. Set MILVUS_NIX_DROP_NIX_CMAKE_FOR_CONAN=1 to restore the older behavior if needed.
run_conan() {
  if [[ "${MILVUS_NIX_CLANG_LIBCXX:-0}" == "1" ]]; then
    local sanitized_path="${PATH}"
    if [[ "${MILVUS_NIX_DROP_NIX_CMAKE_FOR_CONAN:-0}" == "1" ]]; then
      sanitized_path="$({ printf '%s' "${sanitized_path}" | tr ':' '\n' | awk '!($0 ~ /^\/nix\/store\/.*-cmake-[^/]*\/bin$/)' | paste -sd: -; } )"
    fi
    env \
      -u LD_LIBRARY_PATH \
      -u PYTHONPATH \
      -u PYTHONHOME \
      -u PYTHONNOUSERSITE \
      PATH="${sanitized_path}" \
      conan "$@"
  else
    conan "$@"
  fi
}

compiler_major_version() {
  local compiler_bin="$1"
  local version
  version="$({ "${compiler_bin}" -dumpfullversion -dumpversion 2>/dev/null || true; } | head -n1)"
  if [[ -z "${version}" ]]; then
    version="$({ "${compiler_bin}" --version 2>/dev/null || true; } | sed -n '1s/.*version \([0-9][0-9]*\).*/\1/p')"
  fi
  version="${version%%.*}"
  echo "${version}"
}

ensure_conan_supports_compiler_version() {
  local compiler_name="$1"
  local compiler_version="$2"
  local conan_home settings_file conan_python

  if [[ -n "${CONAN_USER_HOME:-}" ]]; then
    conan_home="${CONAN_USER_HOME}/.conan"
  else
    conan_home="$(run_conan config home 2>/dev/null | grep -E '/\.conan$|\\.conan$' | tail -n1 | tr -d '\r')"
    if [[ -z "${conan_home}" ]]; then
      return 0
    fi
  fi
  settings_file="${conan_home}/settings.yml"

  conan_python="$(python3 - <<'PY'
from pathlib import Path
import os
import sys

conan_path = os.popen('command -v conan').read().strip()
if not conan_path:
    sys.exit(0)
try:
    first = Path(conan_path).read_text().splitlines()[0]
except Exception:
    first = ''
if first.startswith('#!'):
    print(first[2:].strip())
PY
)"
  if [[ -z "${conan_python}" ]]; then
    conan_python="$(command -v python3 || true)"
  fi
  if [[ -z "${conan_python}" ]]; then
    return 0
  fi

  "${conan_python}" - "${settings_file}" "${compiler_name}" "${compiler_version}" <<'PY'
from pathlib import Path
import importlib
import sys

settings_path = Path(sys.argv[1])
compiler_name = sys.argv[2]
compiler_version = sys.argv[3]
settings_path.parent.mkdir(parents=True, exist_ok=True)

if not settings_path.exists():
    try:
        conans = importlib.import_module("conans")
        migrations = importlib.import_module("conans.client.migrations_settings")
        version_key = f"settings_{conans.__version__.replace('.', '_')}"
        default_settings = getattr(migrations, version_key)
    except Exception:
        default_settings = None
    if not default_settings:
        sys.exit(0)
    settings_path.write_text(default_settings if default_settings.endswith("\n") else default_settings + "\n")
    print(f"Seeded {settings_path} from Conan defaults")

lines = settings_path.read_text().splitlines()
compiler_header = f"{compiler_name}:"

in_block = False
version_start = None
version_end = None
for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped == compiler_header:
        in_block = True
        continue
    if in_block and line.startswith("    ") and stripped.endswith(":") and not line.startswith("        "):
        break
    if in_block and stripped.startswith("version:"):
        version_start = i
        version_end = i
        while version_end < len(lines) and "]" not in lines[version_end]:
            version_end += 1
        break

if version_start is None or version_end is None or version_end >= len(lines):
    sys.exit(0)

version_blob = "\n".join(lines[version_start:version_end + 1])
needle = f'"{compiler_version}"'
if needle in version_blob:
    print(f"Conan settings already include {compiler_name} {compiler_version}")
    sys.exit(0)

last_line = lines[version_end]
closing = last_line.rfind("]")
if closing == -1:
    sys.exit(0)
insert = f', "{compiler_version}"'
lines[version_end] = last_line[:closing] + insert + last_line[closing:]
settings_path.write_text("\n".join(lines) + "\n")
print(f"Patched {settings_path} to admit {compiler_name} {compiler_version}")
PY
}

ensure_conan_profile_env() {
  local profile_file="$1"
  local key="$2"
  local value="$3"

  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 0
  [[ -n "${key}" ]] || return 0

  python3 - "${profile_file}" "${key}" "${value}" <<'PY'
from pathlib import Path
import sys

profile_path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = profile_path.read_text().splitlines()
entry = f"{key}={value}"

section_idx = None
for i, line in enumerate(lines):
    if line.strip() == "[env]":
        section_idx = i
        break

if section_idx is None:
    if lines and lines[-1].strip():
        lines.append("")
    lines.extend(["[env]", entry])
else:
    insert_at = len(lines)
    for i in range(section_idx + 1, len(lines)):
        stripped = lines[i].strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            insert_at = i
            break
        if stripped.startswith(f"{key}="):
            lines[i] = entry
            break
    else:
        lines.insert(insert_at, entry)

profile_path.write_text("\n".join(lines) + "\n")
print(f"Updated {profile_path}: {entry}")
PY
}

pushd ${BUILD_OUTPUT_DIR}

export CONAN_REVISIONS_ENABLED=1
export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-Wno-error=address -Wno-error=deprecated-declarations -Wno-error=unused-command-line-argument -include cstdint"
export CFLAGS="${CFLAGS:+${CFLAGS} }-Wno-error=address -Wno-error=deprecated-declarations -Wno-error=unused-command-line-argument"
# Allow CMake 4.x to build packages with old cmake_minimum_required versions (< 3.5)
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# Local overrides (avoid huge builds / fix upstream recipes while keeping public sources)
GOOGLE_CLOUD_CPP_OVERRIDE_DIR="${CPP_SRC_DIR}/conan/overrides/google-cloud-cpp/2.5.0"
# Only export this override when explicitly enabled.
# The storage-only override is useful for offline builds but can break linkage if downstream
# expects other google-cloud-cpp component libraries.
if [[ "${MILVUS_USE_GOOGLE_CLOUD_CPP_OVERRIDE:-0}" == "1" ]] && [[ -f "${GOOGLE_CLOUD_CPP_OVERRIDE_DIR}/conanfile.py" ]]; then
  echo "Exporting local google-cloud-cpp/2.5.0@ override (storage-only)"
  run_conan export "${GOOGLE_CLOUD_CPP_OVERRIDE_DIR}" google-cloud-cpp/2.5.0@
fi

GNU_CONFIG_OVERRIDE_DIR="${CPP_SRC_DIR}/conan/overrides/gnu-config/cci.20210814"
# Only export this override when explicitly enabled.
# Normally we prefer the official ConanCenter recipe/binaries.
if [[ "${MILVUS_USE_GNU_CONFIG_OVERRIDE:-0}" == "1" ]] && [[ -f "${GNU_CONFIG_OVERRIDE_DIR}/conanfile.py" ]]; then
  echo "Exporting local gnu-config override (offline-friendly)"
  run_conan export "${GNU_CONFIG_OVERRIDE_DIR}"
fi

LIBAVROCPP_OVERRIDE_DIR="${CPP_SRC_DIR}/conan/overrides/libavrocpp/1.11.3"
BOOST_OVERRIDE_DIR="${CPP_SRC_DIR}/conan/overrides/boost/1.85.0"
GOOGLE_CLOUD_CPP_OVERRIDE_DIR="${CPP_SRC_DIR}/conan/overrides/google-cloud-cpp/2.5.0"
OPENTELEMETRY_CPP_OVERRIDE_DIR="${CPP_SRC_DIR}/conan/overrides/opentelemetry-cpp/1.9.1"
LIBIBERTY_OVERRIDE_DIR="${CPP_SRC_DIR}/conan/overrides/libiberty/9.1.0"
LIBSYSTEMD_OVERRIDE_DIR="${CPP_SRC_DIR}/conan/overrides/libsystemd/255"
# Linux clang+libc++ currently hits a non-library avrogencpp/Boost ABI failure in the
# upstream recipe. Export a local recipe override that still uses public sources but
# skips the unused avrogencpp/test-codegen executable path.
if [[ "${MILVUS_NIX_CLANG_LIBCXX:-0}" == "1" ]] && [[ -f "${LIBAVROCPP_OVERRIDE_DIR}/conanfile.py" ]]; then
  echo "Exporting local libavrocpp/1.11.3@ override (skip avrogencpp/test-codegen on clang+libc++)"
  run_conan export "${LIBAVROCPP_OVERRIDE_DIR}" libavrocpp/1.11.3@
fi
# boost/1.85.0's default ConanCenter recipe only forwards -stdlib=libc++ to b2.
# Under the Nix proof shell that still lets GCC libstdc++ headers leak in, so export a
# local override that additionally forwards the libc++ header/library flags while keeping
# public ConanCenter sources.
if [[ "${MILVUS_NIX_CLANG_LIBCXX:-0}" == "1" ]] && [[ -f "${BOOST_OVERRIDE_DIR}/conanfile.py" ]]; then
  echo "Exporting local boost/1.85.0@ override (forward Nix libc++ header/link flags to b2)"
  run_conan export "${BOOST_OVERRIDE_DIR}" boost/1.85.0@
fi
# Under the same proof path, Conan's VirtualRunEnv can inject package OpenSSL/libcurl
# directories that poison host-tool CMake startup for google-cloud-cpp. Export the local
# recipe override so the CMake configure/build/install steps scrub loader vars while still
# using public ConanCenter/package sources.
if [[ "${MILVUS_NIX_CLANG_LIBCXX:-0}" == "1" ]] && [[ -f "${GOOGLE_CLOUD_CPP_OVERRIDE_DIR}/conanfile.py" ]]; then
  echo "Exporting local google-cloud-cpp/2.5.0@ override (sanitize loader env for Nix clang+libc++)"
  run_conan export "${GOOGLE_CLOUD_CPP_OVERRIDE_DIR}" google-cloud-cpp/2.5.0@
fi
# opentelemetry-cpp hits the same host-tool loader poisoning during CMake startup when
# Conan injects package OpenSSL/libcurl dirs into LD_LIBRARY_PATH. Keep the proof path on
# public ConanCenter sources by exporting a local recipe override that skips VirtualRunEnv
# and scrubs loader vars only around CMake configure/build/install.
if [[ "${MILVUS_NIX_CLANG_LIBCXX:-0}" == "1" ]] && [[ -f "${OPENTELEMETRY_CPP_OVERRIDE_DIR}/conanfile.py" ]]; then
  echo "Exporting local opentelemetry-cpp/1.9.1@ override (sanitize loader env for Nix clang+libc++)"
  run_conan export "${OPENTELEMETRY_CPP_OVERRIDE_DIR}" opentelemetry-cpp/1.9.1@
fi
# libiberty/9.1.0's default ConanCenter recipe hardcodes ftp.gnu.org, which is unreliable
# through the laptop-backed proxy path used on the Linux proof host. Keep the proof path on
# public GNU sources by exporting a local recipe override that prefers ftpmirror.gnu.org and
# falls back to the canonical ftp.gnu.org URL with the same tarball checksum.
if [[ "${MILVUS_NIX_CLANG_LIBCXX:-0}" == "1" ]] && [[ -f "${LIBIBERTY_OVERRIDE_DIR}/conanfile.py" ]]; then
  echo "Exporting local libiberty/9.1.0@ override (prefer ftpmirror.gnu.org over ftp.gnu.org)"
  run_conan export "${LIBIBERTY_OVERRIDE_DIR}" libiberty/9.1.0@
fi
# systemd 255's Conan recipe hard-fails when newer kernel headers expose filesystem
# magic constants not yet mirrored in filesystems-gperf.gperf. For the Nix clang+libc++
# proof path, keep using public sources but export a local recipe override that downgrades
# that check to a warning so libsystemd can still build on newer Linux hosts.
if [[ "${MILVUS_NIX_CLANG_LIBCXX:-0}" == "1" ]] && [[ -f "${LIBSYSTEMD_OVERRIDE_DIR}/conanfile.py" ]]; then
  echo "Exporting local libsystemd/255@ override (ignore newer-kernel filesystem header drift)"
  run_conan export "${LIBSYSTEMD_OVERRIDE_DIR}" libsystemd/255@
fi

# Conan will use ConanCenter by default (no need for private remote)
# Remove private remote setup - using public ConanCenter packages

unameOut="$(uname -s)"
case "${unameOut}" in
  Darwin*)
    # Use ccache as compiler launcher
    export CMAKE_C_COMPILER_LAUNCHER=ccache
    export CMAKE_CXX_COMPILER_LAUNCHER=ccache
    echo "Using CXX: $CXX"
    echo "Using CC: $CC"
    run_conan install ${CPP_SRC_DIR} --install-folder conan --build=missing -s build_type=${BUILD_TYPE} -s compiler=clang -s compiler.version=${llvm_version} -s compiler.libcxx=libc++ -s compiler.cppstd=20 || { echo 'conan install failed'; exit 1; }
    ;;
  Linux*)
    if [ -f /etc/os-release ]; then
        OS_NAME=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d '=' -f2 | tr -d '"')
    else
        OS_NAME="Linux"
    fi
    echo "Running on ${OS_NAME}"
    export CPU_TARGET=avx
    LINUX_COMPILER="gcc"
    LINUX_COMPILER_BIN="${CXX:-$(command -v g++ || true)}"
    if [[ "$(basename "${CC:-}")" == clang* ]] || [[ "$(basename "${CXX:-}")" == clang++* ]] || [[ "${MILVUS_USE_CLANG:-0}" == "1" ]]; then
      LINUX_COMPILER="clang"
      LINUX_COMPILER_BIN="${CXX:-$(command -v clang++ || true)}"
    fi
    if [[ -z "${LINUX_COMPILER_BIN}" ]]; then
      echo "Unable to locate a ${LINUX_COMPILER} compiler"
      exit 1
    fi
    if [[ "${LINUX_COMPILER}" == "clang" ]]; then
      CONAN_COMPILER_WRAPPER_DIR="${BUILD_OUTPUT_DIR}/conan-compiler-wrap"
      mkdir -p "${CONAN_COMPILER_WRAPPER_DIR}"
      cat > "${CONAN_COMPILER_WRAPPER_DIR}/clang" <<EOF
#!/usr/bin/env bash
exec "${CC:-${LINUX_COMPILER_BIN}}" "\$@"
EOF
      cat > "${CONAN_COMPILER_WRAPPER_DIR}/clang++" <<EOF
#!/usr/bin/env bash
exec "${CXX:-${LINUX_COMPILER_BIN}}" "\$@"
EOF
      chmod +x "${CONAN_COMPILER_WRAPPER_DIR}/clang" "${CONAN_COMPILER_WRAPPER_DIR}/clang++"
      ln -sf clang "${CONAN_COMPILER_WRAPPER_DIR}/clang-${MILVUS_CLANG_VERSION:-${LINUX_COMPILER_VERSION}}"
      ln -sf clang++ "${CONAN_COMPILER_WRAPPER_DIR}/clang++-${MILVUS_CLANG_VERSION:-${LINUX_COMPILER_VERSION}}"
      export PATH="${CONAN_COMPILER_WRAPPER_DIR}:$PATH"
      echo "Conan compiler wrapper PATH head: ${CONAN_COMPILER_WRAPPER_DIR}"
      echo "clang wrapper -> ${CC:-${LINUX_COMPILER_BIN}}"
      echo "clang++ wrapper -> ${CXX:-${LINUX_COMPILER_BIN}}"
    fi
    LINUX_COMPILER_VERSION="$(compiler_major_version "${LINUX_COMPILER_BIN}")"
    if [[ -z "${LINUX_COMPILER_VERSION}" ]]; then
      echo "Unable to determine ${LINUX_COMPILER} compiler version from ${LINUX_COMPILER_BIN}"
      exit 1
    fi
    echo "Using Linux compiler: ${LINUX_COMPILER_BIN} (${LINUX_COMPILER} ${LINUX_COMPILER_VERSION})"

    # Ensure a deterministic profile and avoid Conan using stale compiler settings.
    # On a brand-new CONAN_USER_HOME under /export, Conan 1 may lazily create
    # settings.yml only after a profile command touches the home. Prime that first,
    # then patch in newer compiler majors (for example clang 18) before the install.
    run_conan profile new default --detect --force >/dev/null 2>&1 || true
    run_conan profile show default >/dev/null 2>&1 || true

    if [[ "${LINUX_COMPILER}" == "clang" ]]; then
      ensure_conan_supports_compiler_version "clang" "${LINUX_COMPILER_VERSION}"
    fi
    run_conan profile update settings.compiler=${LINUX_COMPILER} default >/dev/null 2>&1 || true
    run_conan profile update settings.compiler.version=${LINUX_COMPILER_VERSION} default >/dev/null 2>&1 || true
    CONAN_HOME_DIR="${CONAN_USER_HOME:-$HOME}/.conan"
    DEFAULT_CONAN_PROFILE="${CONAN_HOME_DIR}/profiles/default"
    if [[ -f "${DEFAULT_CONAN_PROFILE}" ]]; then
      ensure_conan_profile_env "${DEFAULT_CONAN_PROFILE}" CC "${CC:-}"
      ensure_conan_profile_env "${DEFAULT_CONAN_PROFILE}" CXX "${CXX:-}"
      ensure_conan_profile_env "${DEFAULT_CONAN_PROFILE}" CFLAGS "${CFLAGS:-}"
      ensure_conan_profile_env "${DEFAULT_CONAN_PROFILE}" CXXFLAGS "${CXXFLAGS:-}"
      ensure_conan_profile_env "${DEFAULT_CONAN_PROFILE}" CPPFLAGS "${CPPFLAGS:-}"
      ensure_conan_profile_env "${DEFAULT_CONAN_PROFILE}" LDFLAGS "${LDFLAGS:-}"
      ensure_conan_profile_env "${DEFAULT_CONAN_PROFILE}" CPATH "${CPATH:-}"
      ensure_conan_profile_env "${DEFAULT_CONAN_PROFILE}" CPLUS_INCLUDE_PATH "${CPLUS_INCLUDE_PATH:-}"
      ensure_conan_profile_env "${DEFAULT_CONAN_PROFILE}" LIBRARY_PATH "${LIBRARY_PATH:-}"
    fi
    LINUX_CLANG_STDLIB="${MILVUS_CLANG_STDLIB:-libstdc++11}"
    if [[ "${LINUX_COMPILER}" == "clang" ]]; then
      case "${LINUX_CLANG_STDLIB}" in
        libc++|libstdc++|libstdc++11)
          ;;
        *)
          echo "Unsupported MILVUS_CLANG_STDLIB=${LINUX_CLANG_STDLIB}. Supported values: libc++, libstdc++, libstdc++11"
          exit 1
          ;;
      esac
      echo "Using Linux clang C++ standard library: ${LINUX_CLANG_STDLIB}"
    fi
    GCC_DEFAULT_LIBSTDCPP_ABI=""
    if [[ "${LINUX_COMPILER}" == "gcc" ]]; then
      GCC_DEFAULT_LIBSTDCPP_ABI="$("${LINUX_COMPILER_BIN}" -v 2>&1 | sed -n 's/.*\(--with-default-libstdcxx-abi\)=\(\w*\).*/\2/p')"
    fi
    if [[ "${LINUX_COMPILER}" == "clang" ]]; then
      run_conan profile update settings.compiler.libcxx=${LINUX_CLANG_STDLIB} default >/dev/null 2>&1 || true
    elif [[ "${GCC_DEFAULT_LIBSTDCPP_ABI}" != "gcc4" ]]; then
      run_conan profile update settings.compiler.libcxx=libstdc++11 default >/dev/null 2>&1 || true
    fi

    # Conan build policy.
    # - Default: "--build=missing" (use local cache binaries when present; build what is missing)
    # - If conancenter is disabled (offline): force local builds to avoid attempted downloads,
    #   but exclude tool packages that may try to fetch upstream tarballs (e.g. cmake).
    # - You can override by exporting CONAN_BUILD_ARG yourself.
    if [[ -z "${CONAN_BUILD_ARG:-}" ]]; then
      CONAN_BUILD_ARG="--build=missing"
      if run_conan remote list 2>/dev/null | grep -qi "conancenter:.*Disabled: True"; then
        CONAN_BUILD_ARG="--build=* --build=!cmake/* --build=!pkgconf/* --build=!nlohmann_json/* --build=!opentelemetry-proto/*"
      fi
    fi
    # Explicit override: build everything from source
    if [[ "${CONAN_FORCE_BUILD_ALL:-0}" == "1" ]]; then
      CONAN_BUILD_ARG="--build=*"
    fi

    # Prefer Conan-provided CMake when we need a newer host toolchain CMake.
    # Under the Nix clang+libc++ proof path we default to the Nix shell's CMake so tools run
    # inside the same libc/OpenSSL world, but allow an explicit Conan-CMake override for cases
    # where Conan's per-package runtime library dirs make the Nix CMake binary pick up an
    # incompatible libssl/libcrypto at process start.
    CONAN_HOME_DIR="${CONAN_USER_HOME:-$HOME}/.conan"
    CONAN_CMAKE_EXE=""
    if [[ -d "${CONAN_HOME_DIR}/data/cmake/3.30.5/_/_/package" ]]; then
      CONAN_CMAKE_EXE=$(find "${CONAN_HOME_DIR}/data/cmake/3.30.5/_/_/package" -maxdepth 3 -type f -name cmake 2>/dev/null | head -n1 || true)
    fi
    if [[ "${MILVUS_NIX_CLANG_LIBCXX:-0}" == "1" ]] && [[ "${MILVUS_NIX_FORCE_CONAN_CMAKE:-0}" != "1" ]]; then
      echo "Using Nix shell CMake: $(cmake --version | head -n1)"
    elif [[ -n "${CONAN_CMAKE_EXE}" ]]; then
      export PATH="$(dirname "${CONAN_CMAKE_EXE}"):${PATH}"
      echo "Using Conan CMake: $(${CONAN_CMAKE_EXE} --version | head -n1)"
    fi

    SELECTED_CMAKE="$(command -v cmake)"
    if [[ "${MILVUS_NIX_CLANG_LIBCXX:-0}" == "1" ]]; then
      BUILD_TOOL_LOADER_PATH="$(printf '%s' "${LD_LIBRARY_PATH:-}" | tr ':' '\n' | awk '/^\/nix\/store\// { print }' | paste -sd: -)"
      CONAN_CMAKE_WRAPPER_DIR="${BUILD_OUTPUT_DIR}/conan-toolwrap"
      CONAN_CMAKE_WRAPPER="${CONAN_CMAKE_WRAPPER_DIR}/cmake"
      mkdir -p "${CONAN_CMAKE_WRAPPER_DIR}"
      cat > "${CONAN_CMAKE_WRAPPER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export LD_LIBRARY_PATH="${BUILD_TOOL_LOADER_PATH}"
unset DYLD_LIBRARY_PATH
exec "${SELECTED_CMAKE}" "\$@"
EOF
      chmod +x "${CONAN_CMAKE_WRAPPER}"
      export PATH="${CONAN_CMAKE_WRAPPER_DIR}:${PATH}"
      export CONAN_CMAKE_PROGRAM="${CONAN_CMAKE_WRAPPER}"
      echo "Conan will invoke CMake via wrapper: ${CONAN_CMAKE_PROGRAM} -> ${SELECTED_CMAKE}"
      echo "Wrapper LD_LIBRARY_PATH=${BUILD_TOOL_LOADER_PATH}"
    else
      export CONAN_CMAKE_PROGRAM="${SELECTED_CMAKE}"
      echo "Conan will invoke CMake via: ${CONAN_CMAKE_PROGRAM}"
    fi

    if [[ "${LINUX_COMPILER}" == "clang" ]]; then
      run_conan install ${CPP_SRC_DIR} --install-folder conan ${CONAN_BUILD_ARG} -s build_type=${BUILD_TYPE} -s compiler=clang -s compiler.version=${LINUX_COMPILER_VERSION} -s compiler.libcxx=${LINUX_CLANG_STDLIB} -s compiler.cppstd=20 || { echo 'conan install failed'; exit 1; }
    elif [[ "${GCC_DEFAULT_LIBSTDCPP_ABI}" == "gcc4" ]]; then
      run_conan install ${CPP_SRC_DIR} --install-folder conan ${CONAN_BUILD_ARG} -s build_type=${BUILD_TYPE} -s compiler=gcc -s compiler.version=${LINUX_COMPILER_VERSION} || { echo 'conan install failed'; exit 1; }
    else
      run_conan install ${CPP_SRC_DIR} --install-folder conan ${CONAN_BUILD_ARG} -s build_type=${BUILD_TYPE} -s compiler=gcc -s compiler.version=${LINUX_COMPILER_VERSION} -s compiler.libcxx=libstdc++11 || { echo 'conan install failed'; exit 1; }
    fi

    # Fix Conan-generated FindAWSSDK.cmake: some CMakeLists use COMPONENTS core/s3/...
    # but the Conan generator names it aws-sdk-cpp-core. Provide a compatible alias.
    if [[ -f conan/FindAWSSDK.cmake ]]; then
      if ! grep -q "AWS::core" conan/FindAWSSDK.cmake; then
        sed -i 's/^set(AWS_COMPONENTS /set(AWS_COMPONENTS AWS::core /' conan/FindAWSSDK.cmake || true
      fi
      if ! grep -q "add_library(AWS::core" conan/FindAWSSDK.cmake; then
        cat >> conan/FindAWSSDK.cmake <<'EOF'

# Milvus compatibility: map AWS::core to Conan target AWS::aws-sdk-cpp-core
if(TARGET AWS::aws-sdk-cpp-core AND NOT TARGET AWS::core)
  add_library(AWS::core ALIAS AWS::aws-sdk-cpp-core)
endif()
EOF
      fi
    fi

    # Fix Conan-generated Findfolly.cmake casing/variables for projects that call find_package(Folly)
    # Conan emits Findfolly.cmake (lowercase), which won't satisfy find_package(Folly) on Linux.
    if [[ -f conan/Findfolly.cmake && ! -f conan/FindFolly.cmake ]]; then
      cat > conan/FindFolly.cmake <<'EOF'
# Wrapper for Conan-generated Findfolly.cmake
# Provides the expected FindFolly.cmake entrypoint + Folly_FOUND/Folly_VERSION vars.
include("${CMAKE_CURRENT_LIST_DIR}/Findfolly.cmake")
set(Folly_FOUND ${folly_FOUND})
set(Folly_VERSION ${folly_VERSION})
EOF
    fi

    # Fix fmt target naming mismatch:
    # Some thirdparty CMake expects fmt::fmt-header-only, while Conan's Findfmt.cmake only defines fmt::fmt.
    if [[ -f conan/Findfmt.cmake ]]; then
      if ! grep -q "fmt::fmt-header-only" conan/Findfmt.cmake; then
        cat >> conan/Findfmt.cmake <<'EOF'

# Milvus compatibility: provide fmt::fmt-header-only when only fmt::fmt exists
if(TARGET fmt::fmt AND NOT TARGET fmt::fmt-header-only)
  add_library(fmt::fmt-header-only INTERFACE IMPORTED)

  get_target_property(_fmt_inc fmt::fmt INTERFACE_INCLUDE_DIRECTORIES)
  if(_fmt_inc)
    set_target_properties(fmt::fmt-header-only PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${_fmt_inc}")
  endif()

  get_target_property(_fmt_defs fmt::fmt INTERFACE_COMPILE_DEFINITIONS)
  if(_fmt_defs)
    set_target_properties(fmt::fmt-header-only PROPERTIES INTERFACE_COMPILE_DEFINITIONS "${_fmt_defs}")
  endif()

  get_target_property(_fmt_opts fmt::fmt INTERFACE_COMPILE_OPTIONS)
  if(_fmt_opts)
    set_target_properties(fmt::fmt-header-only PROPERTIES INTERFACE_COMPILE_OPTIONS "${_fmt_opts}")
  endif()

  get_target_property(_fmt_libs fmt::fmt INTERFACE_LINK_LIBRARIES)
  if(_fmt_libs)
    set_target_properties(fmt::fmt-header-only PROPERTIES INTERFACE_LINK_LIBRARIES "${_fmt_libs}")
  else()
    set_target_properties(fmt::fmt-header-only PROPERTIES INTERFACE_LINK_LIBRARIES fmt::fmt)
  endif()
endif()
EOF
      fi
    fi
    ;;
  *)
    echo "Cannot build on windows"
    ;;
esac

popd

mkdir -p ${ROOT_DIR}/internal/core/output/lib
mkdir -p ${ROOT_DIR}/internal/core/output/include

mkdir -p ${ROOT_DIR}/cmake_build/thirdparty
pushd ${ROOT_DIR}/cmake_build/thirdparty
if command -v cargo >/dev/null 2>&1; then
    echo "cargo exists"
    unameOut="$(uname -s)"
    case "${unameOut}" in
        Darwin*)
          echo "running on mac os, reinstall rust 1.89"
          # github will install rust 1.74 by default.
          # https://github.com/actions/runner-images/blob/main/images/macos/macos-12-Readme.md
          rustup install 1.89
          rustup default 1.89;;
        *)
          echo "not running on mac os, no need to reinstall rust";;
    esac
else
    bash -c "curl https://sh.rustup.rs -sSf | sh -s -- --default-toolchain=1.89 -y" || { echo 'rustup install failed'; exit 1;}
    source $HOME/.cargo/env
fi
