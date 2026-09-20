#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
SOURCE_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${ARMSX3_IOS_BUILD_DIR:-${SOURCE_DIR}/build/ios-device}
DEPS_DIR=${BUILD_DIR}/ios-deps
SRC_DIR=${BUILD_DIR}/dependency-sources
JOBS=${ARMSX3_JOBS:-$(getconf _NPROCESSORS_ONLN)}
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CLANG=$(xcrun --sdk iphoneos --find clang)
CXX=$(xcrun --sdk iphoneos --find clang++)
AR=$(xcrun --sdk iphoneos --find ar)
RANLIB=$(xcrun --sdk iphoneos --find ranlib)
STRIP=$(xcrun --sdk iphoneos --find strip)
MIN_IOS=15.0

mkdir -p ${DEPS_DIR} ${SRC_DIR}

build_ffmpeg() {
    local version=8.1.1
    local archive=${SRC_DIR}/ffmpeg-${version}.tar.xz
    local source=${SRC_DIR}/ffmpeg-${version}
    local prefix=${DEPS_DIR}/ffmpeg

    if [[ -f ${prefix}/lib/libavcodec.a ]]; then
        print "FFmpeg already built"
        return
    fi
    if [[ ! -f ${archive} ]]; then
        curl -L --fail --retry 3 -o ${archive} \
            https://ffmpeg.org/releases/ffmpeg-${version}.tar.xz
    fi
    if [[ ! -d ${source} ]]; then
        tar -xf ${archive} -C ${SRC_DIR}
    fi
    mkdir -p ${source}/build-ios
    pushd ${source}/build-ios >/dev/null
    ../configure \
        --prefix=${prefix} \
        --target-os=darwin \
        --arch=arm64 \
        --cc=${CLANG} \
        --cxx=${CXX} \
        --ar=${AR} \
        --ranlib=${RANLIB} \
        --strip=${STRIP} \
        --sysroot=${SDK} \
        --extra-cflags="-arch arm64 -miphoneos-version-min=${MIN_IOS} -fembed-bitcode-marker" \
        --extra-ldflags="-arch arm64 -miphoneos-version-min=${MIN_IOS}" \
        --enable-cross-compile \
        --enable-static \
        --disable-shared \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --disable-network \
        --disable-autodetect \
        --disable-avdevice \
        --disable-avfilter \
        --enable-avcodec \
        --enable-avformat \
        --enable-avutil \
        --enable-swresample \
        --enable-swscale
    make -j${JOBS}
    make install
    popd >/dev/null
}

build_moltenvk() {
    local source=${SRC_DIR}/MoltenVK
    local prefix=${DEPS_DIR}/moltenvk
    if [[ -f ${prefix}/lib/libMoltenVK.a ]]; then
        print "MoltenVK already built"
        return
    fi
    if [[ ! -d ${source}/.git ]]; then
        git clone https://github.com/KhronosGroup/MoltenVK.git ${source}
        git -C ${source} checkout 4588705
    fi
    pushd ${source} >/dev/null
    # Xcode 27 no longer accepts the deployment targets stored by this pinned
    # MoltenVK revision. Patch only the generated dependency project.
    sed -i '' -E "s/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = ${MIN_IOS};/g" \
        ExternalDependencies.xcodeproj/project.pbxproj
    sed -i '' -E 's/MACOSX_DEPLOYMENT_TARGET = [0-9.]+;/MACOSX_DEPLOYMENT_TARGET = 12.0;/g' \
        ExternalDependencies.xcodeproj/project.pbxproj
    IPHONEOS_DEPLOYMENT_TARGET=${MIN_IOS} MACOSX_DEPLOYMENT_TARGET=12.0 \
        ./fetchDependencies --ios
    xcodebuild build -quiet \
        -project MoltenVKPackaging.xcodeproj \
        -scheme "MoltenVK Package (iOS only)" \
        -configuration Release \
        -sdk iphoneos \
        -arch arm64 \
        IPHONEOS_DEPLOYMENT_TARGET=${MIN_IOS} \
        CODE_SIGNING_ALLOWED=NO
    popd >/dev/null

    local library=$(find ${source} -path '*/ios-arm64/libMoltenVK.a' -print -quit)
    local headers=${source}/Package/Release/MoltenVK/include
    if [[ -z ${library} || -z ${headers} ]]; then
        print -u2 "Could not locate MoltenVK iOS build products"
        return 1
    fi
    mkdir -p ${prefix}/lib ${prefix}/include
    cp ${library} ${prefix}/lib/libMoltenVK.a
    cp -R ${headers}/. ${prefix}/include/
    if [[ -d ${source}/External/Vulkan-Headers/include/vulkan ]]; then
        cp -R ${source}/External/Vulkan-Headers/include/vulkan ${prefix}/include/
    fi
}

build_llvm() {
    local source=${SOURCE_DIR}/3rdparty/llvm/llvm/llvm
    local build=${BUILD_DIR}/llvm-ios-build
    local prefix=${DEPS_DIR}/llvm
    local tablegen=${ARMSX3_LLVM_TABLEGEN:-/opt/homebrew/opt/llvm@22/bin/llvm-tblgen}
    if [[ -f ${prefix}/lib/cmake/llvm/LLVMConfig.cmake ]]; then
        print "LLVM already built"
        return
    fi
    if [[ ! -x ${tablegen} ]]; then
        print -u2 "Host llvm-tblgen 22 is required; set ARMSX3_LLVM_TABLEGEN"
        return 1
    fi
    cmake -S ${source} -B ${build} -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=${MIN_IOS} \
        -DCMAKE_INSTALL_PREFIX=${prefix} \
        -DLLVM_TABLEGEN=${tablegen} \
        -DLLVM_NATIVE_TOOL_DIR=${tablegen:h} \
        -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios${MIN_IOS} \
        -DLLVM_TARGETS_TO_BUILD=AArch64 \
        -DLLVM_ENABLE_PROJECTS= \
        -DLLVM_BUILD_TOOLS=OFF \
        -DLLVM_INCLUDE_TOOLS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_DOCS=OFF \
        -DLLVM_INCLUDE_UTILS=OFF \
        -DLLVM_BUILD_UTILS=OFF \
        -DLLVM_INCLUDE_RUNTIMES=OFF \
        -DLLVM_BUILD_RUNTIMES=OFF \
        -DLLVM_BUILD_RUNTIME=OFF \
        -DLLVM_NO_DEAD_STRIP=ON \
        -DLLVM_BUILD_LLVM_DYLIB=OFF \
        -DLLVM_LINK_LLVM_DYLIB=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_CURL=OFF \
        -DLLVM_ENABLE_RTTI=OFF \
        -DLLVM_ENABLE_EH=OFF
    cmake --build ${build} -j${JOBS}
    cmake --install ${build}
}

case ${1:-all} in
    ffmpeg) build_ffmpeg ;;
    moltenvk) build_moltenvk ;;
    llvm) build_llvm ;;
    all)
        build_ffmpeg
        build_moltenvk
        build_llvm
        ;;
    *) print -u2 "usage: $0 [all|ffmpeg|moltenvk|llvm]"; exit 2 ;;
esac
