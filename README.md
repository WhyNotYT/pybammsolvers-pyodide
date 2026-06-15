Repository for the C/C++ solvers used in PyBaMM for Pyodide

## Installation

You can just download the pre built wheel from the realeases or `/dist` folder.

## Building from source

```bash
git clone https://github.com/WhyNotYT/pybammsolvers-pyodide
cd pybammsolvers-pyodide
```

Set up pyodide build and emscripten. (Use python 3.13 for pyodide 0.29)

```bash
python -m venv .venv

source .venv/bin/activate

pip install pyodide-build==0.29.3 "wheel<0.42.0"

pyodide xbuildenv install 0.29.3

git clone https://github.com/emscripten-core/emsdk
cd emsdk

PYODIDE_EMSCRIPTEN_VERSION=$(pyodide config get emscripten_version)
./emsdk install ${PYODIDE_EMSCRIPTEN_VERSION}
./emsdk activate ${PYODIDE_EMSCRIPTEN_VERSION}

cd ..
```

Clone SuiteSpare and Sundials, and build.

```bash
git clone https://github.com/DrTimothyAldenDavis/SuiteSparse --depth=1
git clone https://github.com/llnl/sundials --depth=1



./wasm-build.sh

```
