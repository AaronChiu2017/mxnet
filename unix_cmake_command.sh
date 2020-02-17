rm -rf build
mkdir -p build && cd build
cmake -GNinja -C ../config.cmake ..
cmake --build . --parallel 8
