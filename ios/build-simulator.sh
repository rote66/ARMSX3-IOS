#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
SOURCE_DIR=${SCRIPT_DIR:h}
export ARMSX3_IOS_SDK=iphonesimulator
export ARMSX3_IOS_BUILD_DIR=${ARMSX3_IOS_BUILD_DIR:-${SOURCE_DIR}/build/ios-simulator}
BUILD_DIR=${ARMSX3_IOS_BUILD_DIR}
DEPS_DIR=${BUILD_DIR}/ios-deps
CONFIGURATION=${ARMSX3_CONFIGURATION:-Release}
BUILD_JOBS=${ARMSX3_IOS_BUILD_JOBS:-4}

if [[ -d ${SOURCE_DIR}/build/ios-device/dependency-sources ]]; then
    export ARMSX3_IOS_DEPENDENCY_SOURCES_DIR=${ARMSX3_IOS_DEPENDENCY_SOURCES_DIR:-${SOURCE_DIR}/build/ios-device/dependency-sources}
fi

if [[ -n ${ARMSX3_CMAKE:-} ]]; then
    CMAKE_BIN=${ARMSX3_CMAKE}
elif (( $+commands[cmake] )); then
    CMAKE_BIN=${commands[cmake]}
elif [[ -x /opt/homebrew/bin/cmake ]]; then
    CMAKE_BIN=/opt/homebrew/bin/cmake
elif [[ -x /usr/local/bin/cmake ]]; then
    CMAKE_BIN=/usr/local/bin/cmake
else
    print -u2 "CMake 3.28 or newer is required; install it or set ARMSX3_CMAKE"
    exit 1
fi

zsh ${SCRIPT_DIR}/build-dependencies.sh all

"${CMAKE_BIN}" -S ${SOURCE_DIR} -B ${BUILD_DIR} -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DARMSX3_IOS_DEPS_DIR=${DEPS_DIR} \
    -DLLVM_DIR=${DEPS_DIR}/llvm/lib/cmake/llvm \
    -DWITH_LLVM=ON \
    -DBUILD_LLVM=OFF \
    -DSTATIC_LINK_LLVM=ON \
    -DUSE_NATIVE_INSTRUCTIONS=OFF \
    -DUSE_LTO=OFF \
    -DUSE_FAUDIO=OFF \
    -DUSE_SDL=OFF \
    -DUSE_SYSTEM_SDL=OFF \
    -DUSE_SYSTEM_CURL=OFF \
    -DUSE_LIBEVDEV=OFF \
    -DUSE_DISCORD_RPC=OFF \
    -DUSE_SYSTEM_OPENCV=OFF \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO

"${CMAKE_BIN}" --build ${BUILD_DIR} --config ${CONFIGURATION} --target ARMSX3 -- \
    -sdk iphonesimulator -jobs ${BUILD_JOBS} -quiet

APP=${BUILD_DIR}/bin/ARMSX3.app
codesign --force --sign - ${APP}
codesign --verify --deep --strict ${APP}
xcrun vtool -show-build ${APP}/ARMSX3
print "Simulator app: ${APP}"
