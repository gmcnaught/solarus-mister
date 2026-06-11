# CMake cross-compilation toolchain for MiSTer armhf (arm-linux-gnueabihf).
# Used by scripts/build_engine.sh:  cmake -DCMAKE_TOOLCHAIN_FILE=this ...
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(triple arm-linux-gnueabihf)
set(CMAKE_C_COMPILER   ${triple}-gcc)
set(CMAKE_CXX_COMPILER ${triple}-g++)

# Multiarch sysroot: :armhf dev packages install under /usr/lib/arm-linux-gnueabihf
# and /usr/include. Search there for libs/headers, host paths for programs.
set(CMAKE_FIND_ROOT_PATH /usr/${triple} /usr/lib/${triple})
set(CMAKE_LIBRARY_ARCHITECTURE ${triple})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# MiSTer DE10-Nano: Cortex-A9, NEON, hard-float.
set(CMAKE_C_FLAGS_INIT   "-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard")
set(CMAKE_CXX_FLAGS_INIT "-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard")
