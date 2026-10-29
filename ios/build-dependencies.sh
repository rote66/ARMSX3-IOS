#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
SOURCE_DIR=${SCRIPT_DIR:h}
IOS_SDK=${ARMSX3_IOS_SDK:-iphoneos}
case ${IOS_SDK} in
    iphoneos)
        BUILD_VARIANT=ios-device
        TARGET_TRIPLE=arm64-apple-ios15.0
        MOLTENVK_PLATFORM=ios-arm64
        ;;
    iphonesimulator)
        BUILD_VARIANT=ios-simulator
        TARGET_TRIPLE=arm64-apple-ios15.0-simulator
        MOLTENVK_PLATFORM=ios-arm64-simulator
        ;;
    *) print -u2 "Unsupported iOS SDK: ${IOS_SDK}"; exit 2 ;;
esac
BUILD_DIR=${ARMSX3_IOS_BUILD_DIR:-${SOURCE_DIR}/build/${BUILD_VARIANT}}
DEPS_DIR=${BUILD_DIR}/ios-deps
SRC_DIR=${ARMSX3_IOS_DEPENDENCY_SOURCES_DIR:-${BUILD_DIR}/dependency-sources}
JOBS=${ARMSX3_JOBS:-$(getconf _NPROCESSORS_ONLN)}
SDK=$(xcrun --sdk ${IOS_SDK} --show-sdk-path)
CLANG=$(xcrun --sdk ${IOS_SDK} --find clang)
CXX=$(xcrun --sdk ${IOS_SDK} --find clang++)
AR=$(xcrun --sdk ${IOS_SDK} --find ar)
RANLIB=$(xcrun --sdk ${IOS_SDK} --find ranlib)
STRIP=$(xcrun --sdk ${IOS_SDK} --find strip)
MIN_IOS=15.0
ABSEIL_VERSION=20250512.1

resolve_cmake() {
    if [[ -n ${ARMSX3_CMAKE:-} ]]; then
        if [[ ! -x ${ARMSX3_CMAKE} ]]; then
            print -u2 "ARMSX3_CMAKE is not executable: ${ARMSX3_CMAKE}"
            return 1
        fi
        print -r -- ${ARMSX3_CMAKE}
        return
    fi

    if (( $+commands[cmake] )); then
        print -r -- ${commands[cmake]}
        return
    fi

    for candidate in /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
        if [[ -x ${candidate} ]]; then
            print -r -- ${candidate}
            return
        fi
    done

    print -u2 "CMake 3.28 or newer is required; install it or set ARMSX3_CMAKE"
    return 1
}

CMAKE_BIN=$(resolve_cmake)

mkdir -p ${DEPS_DIR} ${SRC_DIR}

prepare_abseil() {
    # RPCS3 builds protobuf from its submodule. Current protobuf needs Abseil,
    # while the app configure intentionally uses FETCHCONTENT_FULLY_DISCONNECTED
    # so it never performs surprise network downloads. Populate the exact
    # FetchContent source directory here, alongside the other explicit iOS deps.
    local source=${BUILD_DIR}/_deps/absl-src
    if [[ -f ${source}/CMakeLists.txt ]]; then
        print "Abseil source already prepared"
        return
    fi
    local device_source=${SOURCE_DIR}/build/ios-device/_deps/absl-src
    if [[ ${IOS_SDK} == iphonesimulator && -f ${device_source}/CMakeLists.txt ]]; then
        mkdir -p ${BUILD_DIR}/_deps
        ditto ${device_source} ${source}
        return
    fi
    rm -rf ${source}
    mkdir -p ${BUILD_DIR}/_deps
    git clone --depth 1 --branch ${ABSEIL_VERSION} \
        https://github.com/abseil/abseil-cpp.git ${source}
}

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
    local build=${source}/build-ios
    if [[ ${IOS_SDK} == iphonesimulator ]]; then
        build=${source}/build-ios-simulator
    fi
    mkdir -p ${build}
    pushd ${build} >/dev/null
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
        --extra-cflags="-target ${TARGET_TRIPLE}" \
        --extra-ldflags="-target ${TARGET_TRIPLE}" \
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
    local dependency_platform=--ios
    if [[ ${IOS_SDK} == iphonesimulator ]]; then
        dependency_platform=--iossim
    fi
    IPHONEOS_DEPLOYMENT_TARGET=${MIN_IOS} MACOSX_DEPLOYMENT_TARGET=12.0 \
        ./fetchDependencies ${dependency_platform}
    xcodebuild build -quiet \
        -project MoltenVKPackaging.xcodeproj \
        -scheme "MoltenVK Package (iOS only)" \
        -configuration Release \
        -sdk ${IOS_SDK} \
        -arch arm64 \
        IPHONEOS_DEPLOYMENT_TARGET=${MIN_IOS} \
        CODE_SIGNING_ALLOWED=NO
    popd >/dev/null

    local library=$(find ${source} -path "*/${MOLTENVK_PLATFORM}/libMoltenVK.a" -print -quit)
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
    local ios_patch=${SCRIPT_DIR}/llvm-ios-memalloc.patch
    local ios_patch_stamp=${prefix}/.armsx3-ios-memalloc-v1
    local llvm_repo=${SOURCE_DIR}/3rdparty/llvm/llvm
    local llvm_patch_applied=0

    if [[ -f ${prefix}/lib/cmake/llvm/LLVMConfig.cmake && -f ${ios_patch_stamp} ]]; then
        print "LLVM already built"
        return
    fi
    if [[ ! -x ${tablegen} ]]; then
        print -u2 "Host llvm-tblgen 22 is required; set ARMSX3_LLVM_TABLEGEN"
        return 1
    fi

    # Keep the LLVM submodule pristine. The iOS allocator fix is applied only
    # while building the cross-compiled static libraries and is reverted again
    # after installation. This makes the dependency build reproducible without
    # carrying a modified third-party checkout in the main working tree.
    if [[ -f ${ios_patch} ]]; then
        if git -C ${llvm_repo} apply --check ${ios_patch}; then
            git -C ${llvm_repo} apply ${ios_patch}
            llvm_patch_applied=1
        elif git -C ${llvm_repo} apply --reverse --check ${ios_patch}; then
            llvm_patch_applied=1
        else
            print -u2 "LLVM iOS allocator patch does not apply cleanly"
            return 1
        fi
    fi

    local restore_llvm_patch=''
    if (( llvm_patch_applied )); then
        restore_llvm_patch="git -C '${llvm_repo}' checkout -- llvm/lib/Support/MemAlloc.cpp"
        trap "${restore_llvm_patch}" EXIT INT TERM
    fi

    "${CMAKE_BIN}" -S ${source} -B ${build} -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT=${IOS_SDK} \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=${MIN_IOS} \
        -DCMAKE_INSTALL_PREFIX=${prefix} \
        -DLLVM_TABLEGEN=${tablegen} \
        -DLLVM_NATIVE_TOOL_DIR=${tablegen:h} \
        -DLLVM_DEFAULT_TARGET_TRIPLE=${TARGET_TRIPLE} \
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
    "${CMAKE_BIN}" --build ${build} -j${JOBS}
    "${CMAKE_BIN}" --install ${build}
    touch ${ios_patch_stamp}

    if (( llvm_patch_applied )); then
        eval ${restore_llvm_patch}
        trap - EXIT INT TERM
    fi
}

case ${1:-all} in
    absl) prepare_abseil ;;
    ffmpeg) build_ffmpeg ;;
    moltenvk) build_moltenvk ;;
    llvm) build_llvm ;;
    all)
        prepare_abseil
        build_ffmpeg
        build_moltenvk
        build_llvm
        ;;
    *) print -u2 "usage: $0 [all|absl|ffmpeg|moltenvk|llvm]"; exit 2 ;;
esac
