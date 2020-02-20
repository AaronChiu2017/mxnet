cmake -GNinja -D CMAKE_BUILD_TYPE=Release -D BUILD_opencv_gpu=OFF -D CMAKE_INSTALL_PREFIX=/home/ubuntu/.local/ ..


rm -rf build
mkdir -p build && cd build
cmake -GNinja -D OPENCV_ROOT=~/.local/lib/cmake/opencv4/ -C ../config.cmake ..
cmake --build .



cmake -GNinja -D OpenCV_DIR=/usr/local/Cellar/opencv@3/3.4.5_2/share/OpenCV -C ../config/darwin.cmake ..
