#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMSDK_ENV="${EMSDK_ENV:-$ROOT_DIR/emsdk/emsdk_env.sh}"
VENV_ACTIVATE="${VENV_ACTIVATE:-$ROOT_DIR/.venv/bin/activate}"
CASADI_ROOT_DEFAULT="$ROOT_DIR/.casadi_wasm"
CASADI_VERSION="${CASADI_VERSION:-3.7.0}"
CASADI_TAG="${CASADI_TAG:-$CASADI_VERSION}"
CASADI_SRC_DIR="${CASADI_SRC_DIR:-$ROOT_DIR/casadi-$CASADI_VERSION}"
CASADI_BUILD_DIR="${CASADI_BUILD_DIR:-$ROOT_DIR/build_casadi_wasm}"

# Keep builds reproducible in fresh clones by defaulting to the local
# checkout path even if the parent shell has CASADI_ROOT exported.
CASADI_ROOT="$CASADI_ROOT_DEFAULT"
CASADI_EXPR="${PYBAMM_IDAKLU_EXPR_CASADI:-ON}"
PYODIDE_BUILD_CMD="${PYODIDE_BUILD_CMD:-pyodide build}"
IDAKLU_PREFIX="${IDAKLU_PREFIX:-$ROOT_DIR/.idaklu_wasm}"

usage() {
  cat <<'EOF'
Usage: ./wasm-build.sh [options]

Options:
  --casadi-root <path>      Override CASADI_ROOT (default: ./.casadi_wasm)
  --casadi on|off           Set PYBAMM_IDAKLU_EXPR_CASADI (default: ON)
  --casadi-version <ver>    CasADi version/tag (default: 3.7.0)
  --idaklu-prefix <path>    SuiteSparse/SUNDIALS install prefix (default: ./.idaklu_wasm)
  --clean                   Remove build/dist/.pyodide_build before building
  --no-casadi-root          Unset CASADI_ROOT even if present
  -h, --help                Show this help

Environment overrides:
  EMSDK_ENV, VENV_ACTIVATE, CASADI_ROOT, CASADI_VERSION, CASADI_TAG,
  CASADI_SRC_DIR, CASADI_BUILD_DIR, IDAKLU_PREFIX, PYBAMM_IDAKLU_EXPR_CASADI, PYODIDE_BUILD_CMD
EOF
}

CLEAN=0
UNSET_CASADI_ROOT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --casadi-root)
      CASADI_ROOT="${2:?missing value for --casadi-root}"
      shift 2
      ;;
    --casadi)
      CASADI_EXPR="${2:?missing value for --casadi}"
      if [[ "$CASADI_EXPR" != "ON" && "$CASADI_EXPR" != "OFF" && "$CASADI_EXPR" != "on" && "$CASADI_EXPR" != "off" ]]; then
        echo "error: --casadi must be on|off" >&2
        exit 2
      fi
      CASADI_EXPR="${CASADI_EXPR^^}"
      shift 2
      ;;
    --casadi-version)
      CASADI_VERSION="${2:?missing value for --casadi-version}"
      CASADI_TAG="${CASADI_VERSION}"
      CASADI_SRC_DIR="$ROOT_DIR/casadi-$CASADI_VERSION"
      shift 2
      ;;
    --idaklu-prefix)
      IDAKLU_PREFIX="${2:?missing value for --idaklu-prefix}"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --no-casadi-root)
      UNSET_CASADI_ROOT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"

if [[ ! -f "$EMSDK_ENV" ]]; then
  echo "error: emsdk env script not found: $EMSDK_ENV" >&2
  exit 1
fi
if [[ ! -f "$VENV_ACTIVATE" ]]; then
  echo "error: venv activate script not found: $VENV_ACTIVATE" >&2
  exit 1
fi

if [[ "$CLEAN" -eq 1 ]]; then
  rm -rf "$ROOT_DIR/build" "$ROOT_DIR/dist" "$ROOT_DIR/.pyodide_build" \
    "$ROOT_DIR/build_sundials" "$ROOT_DIR/build_casadi_wasm" \
    "$IDAKLU_PREFIX" "$CASADI_ROOT"
  for d in SuiteSparse/SuiteSparse_config/build SuiteSparse/AMD/build SuiteSparse/COLAMD/build SuiteSparse/BTF/build SuiteSparse/KLU/build; do
    rm -rf "$ROOT_DIR/$d"
  done
fi

echo "[wasm-build] Activating emsdk: $EMSDK_ENV"
# shellcheck disable=SC1090
source "$EMSDK_ENV"

echo "[wasm-build] Activating venv: $VENV_ACTIVATE"
# shellcheck disable=SC1090
source "$VENV_ACTIVATE"

ensure_casadi_wasm() {
  local casadi_lib="$CASADI_ROOT/lib/libcasadi.a"
  if [[ -f "$casadi_lib" ]]; then
    echo "[wasm-build] Using existing CasADi static library: $casadi_lib"
    return
  fi

  echo "[wasm-build] CasADi $CASADI_VERSION not found at $casadi_lib"
  echo "[wasm-build] Fetching CasADi sources (tag: $CASADI_TAG)"
  if [[ ! -d "$CASADI_SRC_DIR/.git" ]]; then
    rm -rf "$CASADI_SRC_DIR"
    git clone --branch "$CASADI_TAG" --depth 1 https://github.com/casadi/casadi.git "$CASADI_SRC_DIR"
  else
    git -C "$CASADI_SRC_DIR" fetch --tags --depth 1 origin "$CASADI_TAG" || true
    git -C "$CASADI_SRC_DIR" checkout "$CASADI_TAG"
  fi

  echo "[wasm-build] Building CasADi for wasm in $CASADI_BUILD_DIR"
  rm -rf "$CASADI_BUILD_DIR"
  mkdir -p "$CASADI_BUILD_DIR" "$CASADI_ROOT"

  emcmake cmake -S "$CASADI_SRC_DIR" -B "$CASADI_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$CASADI_ROOT" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWITH_PYTHON=OFF \
    -DWITH_OPENMP=OFF \
    -DWITH_DL=ON \
    -DWITH_DEEPBIND=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_CXX_FLAGS="-fPIC -fwasm-exceptions -sSUPPORT_LONGJMP" \
    -DCMAKE_C_FLAGS="-fPIC -fwasm-exceptions -sSUPPORT_LONGJMP"

  cmake --build "$CASADI_BUILD_DIR" -j"$(nproc)"
  cmake --install "$CASADI_BUILD_DIR"

  if [[ ! -f "$casadi_lib" ]]; then
    echo "[wasm-build] error: CasADi build completed but $casadi_lib is missing" >&2
    exit 1
  fi
}

ensure_idaklu_wasm() {
  local idas_header="$IDAKLU_PREFIX/include/idas/idas.h"
  local sundials_config="$IDAKLU_PREFIX/include/sundials/sundials_config.h"
  local klu_lib="$IDAKLU_PREFIX/lib/libklu.a"
  local idas_lib="$IDAKLU_PREFIX/lib/libsundials_idas.a"
  local fallback_prefix=""

  # Accept either .idaklu_wasm or .idaklu as an existing prefix.
  for candidate in "$IDAKLU_PREFIX" "$ROOT_DIR/.idaklu_wasm" "$ROOT_DIR/.idaklu"; do
    if [[ -f "$candidate/include/idas/idas.h" && -f "$candidate/include/sundials/sundials_config.h" && -f "$candidate/lib/libklu.a" && -f "$candidate/lib/libsundials_idas.a" ]]; then
      fallback_prefix="$candidate"
      break
    fi
  done

  if [[ -n "$fallback_prefix" && "$fallback_prefix" != "$IDAKLU_PREFIX" ]]; then
    rm -rf "$IDAKLU_PREFIX"
    ln -s "$fallback_prefix" "$IDAKLU_PREFIX"
    echo "[wasm-build] Linked $IDAKLU_PREFIX -> $fallback_prefix"
  fi

  if [[ -f "$idas_header" && -f "$sundials_config" && -f "$klu_lib" && -f "$idas_lib" ]]; then
    echo "[wasm-build] Using existing SuiteSparse/SUNDIALS wasm prefix: $IDAKLU_PREFIX"
    return
  fi

  # Fresh clones may not have submodules populated.
  if [[ -d "$ROOT_DIR/.git" ]]; then
    echo "[wasm-build] Ensuring git submodules are initialized (SuiteSparse, sundials)"
    git submodule update --init --recursive SuiteSparse sundials
  fi

  if [[ ! -f "$ROOT_DIR/SuiteSparse/SuiteSparse_config/CMakeLists.txt" ]]; then
    echo "[wasm-build] error: missing SuiteSparse CMake sources at SuiteSparse/SuiteSparse_config/CMakeLists.txt" >&2
    echo "[wasm-build] If this is not a git clone, populate SuiteSparse and sundials sources manually." >&2
    exit 1
  fi

  echo "[wasm-build] Building SuiteSparse/SUNDIALS into $IDAKLU_PREFIX"
  local old_default_lib_dir="${PYBAMMSOLVERS_DEFAULT_LIB_DIR:-}"
  export PYBAMMSOLVERS_DEFAULT_LIB_DIR="$IDAKLU_PREFIX"
  python "$ROOT_DIR/install_KLU_Sundials.py" --force
  if [[ -n "$old_default_lib_dir" ]]; then
    export PYBAMMSOLVERS_DEFAULT_LIB_DIR="$old_default_lib_dir"
  else
    unset PYBAMMSOLVERS_DEFAULT_LIB_DIR
  fi

  # Some environments install SUNDIALS into emscripten sysroot but not into our
  # local prefix. If that happens, mirror required headers/libs into IDAKLU_PREFIX.
  if [[ ! -f "$idas_header" || ! -f "$sundials_config" ]]; then
    local emscripten_sysroot="${EMSDK:-$ROOT_DIR/emsdk}/upstream/emscripten/cache/sysroot"
    local sys_idas="$emscripten_sysroot/include/idas/idas.h"
    if [[ -f "$sys_idas" ]]; then
      echo "[wasm-build] Repairing $IDAKLU_PREFIX from emscripten sysroot"
      mkdir -p "$IDAKLU_PREFIX/include" "$IDAKLU_PREFIX/lib"
      for d in idas ida nvector sundials sunlinsol sunmatrix sunmemory sunnonlinsol; do
        if [[ -d "$emscripten_sysroot/include/$d" ]]; then
          rm -rf "$IDAKLU_PREFIX/include/$d"
          cp -a "$emscripten_sysroot/include/$d" "$IDAKLU_PREFIX/include/"
        fi
      done
      if [[ -f "$emscripten_sysroot/include/sundials/sundials_config.h" ]]; then
        mkdir -p "$IDAKLU_PREFIX/include/sundials"
        cp -a "$emscripten_sysroot/include/sundials/sundials_config.h" "$IDAKLU_PREFIX/include/sundials/sundials_config.h"
      fi
      for lib in libsundials_idas.a libsundials_sunlinsolklu.a libsundials_sunlinsoldense.a \
                 libsundials_sunlinsolspbcgs.a libsundials_sunmatrixsparse.a \
                 libsundials_nvecserial.a libsundials_core.a; do
        if [[ -f "$emscripten_sysroot/lib/$lib" && ! -f "$IDAKLU_PREFIX/lib/$lib" ]]; then
          cp -a "$emscripten_sysroot/lib/$lib" "$IDAKLU_PREFIX/lib/"
        fi
      done
    fi
  fi

  # Final fallback: copy headers directly from the vendored sundials source tree.
  if [[ (! -f "$idas_header" || ! -f "$sundials_config") && -d "$ROOT_DIR/sundials/include" ]]; then
    echo "[wasm-build] Repairing $IDAKLU_PREFIX headers from vendored sundials/include"
    mkdir -p "$IDAKLU_PREFIX/include"
    for d in idas ida nvector sundials sunlinsol sunmatrix sunmemory sunnonlinsol; do
      if [[ -d "$ROOT_DIR/sundials/include/$d" ]]; then
        rm -rf "$IDAKLU_PREFIX/include/$d"
        cp -a "$ROOT_DIR/sundials/include/$d" "$IDAKLU_PREFIX/include/"
      fi
    done
  fi

  # Final fallback for generated config header: it may exist in build output
  # even when not installed into the prefix.
  if [[ ! -f "$sundials_config" ]]; then
    if [[ -f "$ROOT_DIR/build_sundials/include/sundials/sundials_config.h" ]]; then
      echo "[wasm-build] Repairing sundials_config.h from build_sundials/include"
      mkdir -p "$IDAKLU_PREFIX/include/sundials"
      cp -a "$ROOT_DIR/build_sundials/include/sundials/sundials_config.h" "$sundials_config"
    elif [[ -f "$ROOT_DIR/build_sundials/src/sundials/sundials_config.h" ]]; then
      echo "[wasm-build] Repairing sundials_config.h from build_sundials/src"
      mkdir -p "$IDAKLU_PREFIX/include/sundials"
      cp -a "$ROOT_DIR/build_sundials/src/sundials/sundials_config.h" "$sundials_config"
    fi
  fi

  if [[ ! -f "$idas_header" || ! -f "$sundials_config" ]]; then
    echo "[wasm-build] error: missing required SUNDIALS headers after dependency build" >&2
    [[ -f "$idas_header" ]] || echo "[wasm-build] missing: $idas_header" >&2
    [[ -f "$sundials_config" ]] || echo "[wasm-build] missing: $sundials_config" >&2
    echo "[wasm-build] looked in: $IDAKLU_PREFIX, $ROOT_DIR/.idaklu_wasm, $ROOT_DIR/.idaklu" >&2
    exit 1
  fi
}

export PYBAMM_IDAKLU_EXPR_CASADI="$CASADI_EXPR"
ensure_idaklu_wasm
if [[ "$UNSET_CASADI_ROOT" -eq 1 ]]; then
  unset CASADI_ROOT
  echo "[wasm-build] CASADI_ROOT unset"
else
  export CASADI_ROOT
  if [[ "$PYBAMM_IDAKLU_EXPR_CASADI" == "ON" ]]; then
    ensure_casadi_wasm
  fi
  echo "[wasm-build] CASADI_ROOT=$CASADI_ROOT"
fi
echo "[wasm-build] PYBAMM_IDAKLU_EXPR_CASADI=$PYBAMM_IDAKLU_EXPR_CASADI"

echo "[wasm-build] Running: $PYODIDE_BUILD_CMD"
eval "$PYODIDE_BUILD_CMD"

echo "[wasm-build] Build complete."
if [[ -d "$ROOT_DIR/dist" ]]; then
  ls -1 "$ROOT_DIR/dist"/*.whl 2>/dev/null || true
fi
