import os
import subprocess
import argparse
import platform
import shutil
from os.path import join, isfile
from multiprocessing import cpu_count
import pathlib


def build_solvers():
    DEFAULT_INSTALL_DIR = str(pathlib.Path(__file__).parent.resolve() / ".idaklu_wasm")
    EMSDK_ROOT = str(pathlib.Path(__file__).parent.resolve() / "emsdk")
    EMSCRIPTEN_TOOLCHAIN = str(pathlib.Path(EMSDK_ROOT) / "upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake")

    def safe_remove_dir(path):
        if os.path.exists(path):
            shutil.rmtree(path)

    def install_suitesparse():
        suitesparse_src = pathlib.Path("SuiteSparse").resolve()
        print("-" * 10, "Building SuiteSparse", "-" * 40)

        common_cmake_args = [
            f"-DCMAKE_INSTALL_PREFIX={DEFAULT_INSTALL_DIR}",
            f"-DCMAKE_PREFIX_PATH={DEFAULT_INSTALL_DIR}",
            f"-DCMAKE_TOOLCHAIN_FILE={EMSCRIPTEN_TOOLCHAIN}",
            "-DSUITESPARSE_DEMOS=OFF",
            "-DSUITESPARSE_USE_FORTRAN=OFF",
            "-DSUITESPARSE_USE_OPENMP=OFF",
            "-DSUITESPARSE_USE_BLAS=OFF",
            "-DBLAS_FOUND=TRUE",
            "-DBLAS_LIBRARIES=",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
            "-DCMAKE_BUILD_TYPE=Release",
        ]

        component_extra_args = {
            "SuiteSparse_config": [],
            "AMD": [
                f"-DSuiteSparse_config_DIR={DEFAULT_INSTALL_DIR}/lib/cmake/SuiteSparse_config",
            ],
            "COLAMD": [
                f"-DSuiteSparse_config_DIR={DEFAULT_INSTALL_DIR}/lib/cmake/SuiteSparse_config",
            ],
            "BTF": [
                f"-DSuiteSparse_config_DIR={DEFAULT_INSTALL_DIR}/lib/cmake/SuiteSparse_config",
            ],
            "KLU": [
                f"-DSuiteSparse_config_DIR={DEFAULT_INSTALL_DIR}/lib/cmake/SuiteSparse_config",
                f"-DAMD_DIR={DEFAULT_INSTALL_DIR}/lib/cmake/AMD",
                f"-DCOLAMD_DIR={DEFAULT_INSTALL_DIR}/lib/cmake/COLAMD",
                f"-DBTF_DIR={DEFAULT_INSTALL_DIR}/lib/cmake/BTF",
            ],
        }

        for libdir in ["SuiteSparse_config", "AMD", "COLAMD", "BTF", "KLU"]:
            src_dir = suitesparse_src / libdir
            build_dir = src_dir / "build"
            if build_dir.exists():
                shutil.rmtree(build_dir)
            os.makedirs(build_dir, exist_ok=True)

            extra_args = component_extra_args[libdir]

            print(f"--- Configuring {libdir} ---")
            subprocess.run(
                ["emcmake", "cmake", str(src_dir), *common_cmake_args, *extra_args],
                cwd=build_dir, check=True
            )
            print(f"--- Building {libdir} ---")
            subprocess.run(["cmake", "--build", ".", f"-j{cpu_count()}"], cwd=build_dir, check=True)
            print(f"--- Installing {libdir} ---")
            subprocess.run(["cmake", "--install", "."], cwd=build_dir, check=True)

        # Some toolchains install static archives under lib64. Normalize to lib
        # so downstream checks and CMake args remain stable.
        lib_dir = pathlib.Path(DEFAULT_INSTALL_DIR) / "lib"
        lib64_dir = pathlib.Path(DEFAULT_INSTALL_DIR) / "lib64"
        if (not lib_dir.exists()) and lib64_dir.exists():
            lib_dir.symlink_to("lib64")

    def install_sundials():
        KLU_INCLUDE_DIR = os.path.join(DEFAULT_INSTALL_DIR, "include", "suitesparse")
        KLU_LIBRARY_DIR = os.path.join(DEFAULT_INSTALL_DIR, "lib")

        # Write a cmake initial cache file to bypass cross-compilation find_library issues
        cache_file = pathlib.Path("build_sundials_cache.cmake")
        cache_file.write_text(f"""
    set(KLU_FOUND TRUE CACHE BOOL "" FORCE)
    set(KLU_INCLUDE_DIR "{KLU_INCLUDE_DIR}" CACHE PATH "" FORCE)
    set(KLU_LIBRARY "{KLU_LIBRARY_DIR}/libklu.a" CACHE FILEPATH "" FORCE)
    set(AMD_LIBRARY "{KLU_LIBRARY_DIR}/libamd.a" CACHE FILEPATH "" FORCE)
    set(COLAMD_LIBRARY "{KLU_LIBRARY_DIR}/libcolamd.a" CACHE FILEPATH "" FORCE)
    set(BTF_LIBRARY "{KLU_LIBRARY_DIR}/libbtf.a" CACHE FILEPATH "" FORCE)
    set(SUITESPARSECONFIG_LIBRARY "{KLU_LIBRARY_DIR}/libsuitesparseconfig.a" CACHE FILEPATH "" FORCE)
    set(KLU_LIBRARIES "{KLU_LIBRARY_DIR}/libklu.a;{KLU_LIBRARY_DIR}/libamd.a;{KLU_LIBRARY_DIR}/libcolamd.a;{KLU_LIBRARY_DIR}/libbtf.a;{KLU_LIBRARY_DIR}/libsuitesparseconfig.a" CACHE STRING "" FORCE)
    """)

        cmake_args = [
            f"-C{cache_file.resolve()}",
            f"-DCMAKE_TOOLCHAIN_FILE={EMSCRIPTEN_TOOLCHAIN}",
            "-DENABLE_LAPACK=OFF",
            "-DENABLE_OPENMP=OFF",
            "-DSUNDIALS_INDEX_SIZE=32",
            "-DEXAMPLES_ENABLE_C=OFF",
            "-DEXAMPLES_ENABLE_CXX=OFF",
            "-DEXAMPLES_INSTALL=OFF",
            "-DENABLE_KLU=ON",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
            f"-DKLU_INCLUDE_DIR={KLU_INCLUDE_DIR}",
            f"-DKLU_LIBRARY_DIR={KLU_LIBRARY_DIR}",
            "-DCMAKE_INSTALL_PREFIX=" + DEFAULT_INSTALL_DIR,
            "-DCMAKE_Fortran_COMPILER_WORKS=TRUE",
        ]
        if platform.system() == "Darwin":
            if platform.processor() == "arm":
                OpenMP_C_FLAGS = (
                    "-Xpreprocessor -fopenmp -I/opt/homebrew/opt/libomp/include"
                )
                OpenMP_C_LIB_NAMES = "omp"
                OpenMP_omp_LIBRARY = "/opt/homebrew/opt/libomp/lib/libomp.dylib"
            elif platform.processor() == "i386":
                OpenMP_C_FLAGS = (
                    "-Xpreprocessor -fopenmp -I/usr/local/opt/libomp/include"
                )
                OpenMP_C_LIB_NAMES = "omp"
                OpenMP_omp_LIBRARY = "/usr/local/opt/libomp/lib/libomp.dylib"
            else:
                raise NotImplementedError(
                    f"Unsupported processor architecture: {platform.processor()}. "
                    "Only 'arm' and 'i386' architectures are supported."
                )

            if os.environ.get("CIBUILDWHEEL") != "1":
                print("Using Homebrew OpenMP for macOS build")
                cmake_args += [
                    "-DOpenMP_C_FLAGS=" + OpenMP_C_FLAGS,
                    "-DOpenMP_C_LIB_NAMES=" + OpenMP_C_LIB_NAMES,
                    "-DOpenMP_omp_LIBRARY=" + OpenMP_omp_LIBRARY,
                ]

        build_dir = pathlib.Path("build_sundials")
        if not os.path.exists(build_dir):
            print("\n-" * 10, "Creating build dir", "-" * 40)
            os.makedirs(build_dir)

        sundials_src = "../sundials"
        print("-" * 10, "Running CMake prepare", "-" * 40)
        env = os.environ.copy()
        klu_libs = f"{KLU_LIBRARY_DIR}/libklu.a;{KLU_LIBRARY_DIR}/libamd.a;{KLU_LIBRARY_DIR}/libcolamd.a;{KLU_LIBRARY_DIR}/libbtf.a;{KLU_LIBRARY_DIR}/libsuitesparseconfig.a"
        env["KLU_LIBRARIES"] = klu_libs

        subprocess.run(
            ["emcmake", "cmake", sundials_src, *cmake_args],
            cwd=build_dir, check=True, env=env
        )

        print("-" * 10, "Building SUNDIALS", "-" * 40)
        make_cmd = ["make", f"-j{cpu_count()}", "install"]
        subprocess.run(make_cmd, cwd=build_dir, check=True)

    def check_libraries_installed():
        lib_dirs = [DEFAULT_INSTALL_DIR]

        sundials_files = [
            "libsundials_idas",
            "libsundials_sunlinsolklu",
            "libsundials_sunlinsoldense",
            "libsundials_sunlinsolspbcgs",
            "libsundials_sunmatrixsparse",
            "libsundials_nvecserial",
        ]
        if platform.system() == "Linux":
            sundials_files = [file + ".so" for file in sundials_files]
        elif platform.system() == "Darwin":
            sundials_files = [file + ".dylib" for file in sundials_files]
        sundials_lib_found = True
        for lib_file in sundials_files:
            file_found = False
            for lib_dir in lib_dirs:
                if isfile(join(lib_dir, "lib", lib_file)):
                    print(f"{lib_file} found in {lib_dir}.")
                    file_found = True
                    break
            if not file_found:
                print(
                    f"{lib_file} not found. Proceeding with SUNDIALS library installation."
                )
                sundials_lib_found = False
                break

        suitesparse_files = [
            "libsuitesparseconfig",
            "libklu",
            "libamd",
            "libcolamd",
            "libbtf",
        ]
        is_wasm = "wasm" in DEFAULT_INSTALL_DIR

        if is_wasm:
            sundials_files = [file + ".a" for file in sundials_files]
            suitesparse_files = [file + ".a" for file in suitesparse_files]
        elif platform.system() == "Linux":
            sundials_files = [file + ".so" for file in sundials_files]
            suitesparse_files = [file + ".so" for file in suitesparse_files]
        elif platform.system() == "Darwin":
            sundials_files = [file + ".dylib" for file in sundials_files]
            suitesparse_files = [file + ".dylib" for file in suitesparse_files]
        else:
            raise NotImplementedError(
                f"Unsupported operating system: {platform.system()}. This script currently supports only Linux and macOS."
            )

        suitesparse_lib_found = True
        for lib_file in suitesparse_files:
            file_found = False
            for lib_dir in lib_dirs:
                if isfile(join(lib_dir, "lib", lib_file)):
                    print(f"{lib_file} found in {lib_dir}.")
                    file_found = True
                    break
            if not file_found:
                print(
                    f"{lib_file} not found. Proceeding with SuiteSparse library installation."
                )
                suitesparse_lib_found = False
                break

        return sundials_lib_found, suitesparse_lib_found

    check_build_tools()
    os.environ["CMAKE_BUILD_PARALLEL_LEVEL"] = str(cpu_count())

    parser = argparse.ArgumentParser(
        description="Compile and install Sundials and SuiteSparse."
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Force installation even if libraries are already found. This will overwrite the pre-existing files.",
    )
    args = parser.parse_args()

    if args.force:
        print(
            "The '--force' option is activated: installation will be forced, ignoring any existing libraries."
        )
        safe_remove_dir(pathlib.Path("build_sundials"))
        sundials_found, suitesparse_found = False, False
    else:
        sundials_found, suitesparse_found = check_libraries_installed()

    if not suitesparse_found:
        install_suitesparse()
    if not sundials_found:
        install_sundials()


def check_build_tools():
    try:
        subprocess.run(["make", "--version"])
    except OSError as error:
        raise RuntimeError("Make must be installed.") from error
    try:
        subprocess.run(["cmake", "--version"])
    except OSError as error:
        raise RuntimeError("CMake must be installed.") from error


if __name__ == "__main__":
    build_solvers()
