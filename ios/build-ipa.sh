#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
SOURCE_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${ARMSX3_IOS_BUILD_DIR:-${SOURCE_DIR}/build/ios-device}
DEPS_DIR=${BUILD_DIR}/ios-deps
OUTPUT_DIR=${SOURCE_DIR}/build/ios-output
CONFIGURATION=${ARMSX3_CONFIGURATION:-Release}
BUILD_JOBS=${ARMSX3_IOS_BUILD_JOBS:-2}

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

for dependency in \
    ${BUILD_DIR}/_deps/absl-src/CMakeLists.txt \
    ${DEPS_DIR}/ffmpeg/lib/libavcodec.a \
    ${DEPS_DIR}/moltenvk/lib/libMoltenVK.a \
    ${DEPS_DIR}/llvm/lib/cmake/llvm/LLVMConfig.cmake; do
    if [[ ! -f ${dependency} ]]; then
        print -u2 "Missing dependency: ${dependency}"
        print -u2 "Run ios/build-dependencies.sh first."
        exit 1
    fi
done

"${CMAKE_BIN}" -S ${SOURCE_DIR} -B ${BUILD_DIR} -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
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
    -sdk iphoneos -jobs ${BUILD_JOBS} -quiet

APP=${BUILD_DIR}/bin/ARMSX3.app
if [[ ! -d ${APP} ]]; then
    APP=$(find ${BUILD_DIR} -type d -name ARMSX3.app -print -quit)
fi
if [[ -z ${APP} ]]; then
    print -u2 "ARMSX3.app was not produced"
    exit 1
fi

mkdir -p ${OUTPUT_DIR}/Payload
ditto ${APP} ${OUTPUT_DIR}/Payload/ARMSX3.app
codesign --force --sign - --entitlements ${SCRIPT_DIR}/ARMSX3.entitlements \
    --generate-entitlement-der ${OUTPUT_DIR}/Payload/ARMSX3.app

IPA=${OUTPUT_DIR}/ARMSX3-iOS15-arm64.ipa
ditto -c -k --sequesterRsrc --keepParent ${OUTPUT_DIR}/Payload ${IPA}

codesign --verify --deep --strict ${OUTPUT_DIR}/Payload/ARMSX3.app
SIGNED_ENTITLEMENTS=${OUTPUT_DIR}/signed-entitlements.plist
codesign -d --entitlements :- ${OUTPUT_DIR}/Payload/ARMSX3.app > ${SIGNED_ENTITLEMENTS} 2>/dev/null
for entitlement in \
    get-task-allow \
    com.apple.developer.kernel.extended-virtual-addressing \
    com.apple.developer.kernel.increased-memory-limit; do
    if ! grep -q "<key>${entitlement}</key>" ${SIGNED_ENTITLEMENTS}; then
        print -u2 "Signed app is missing entitlement: ${entitlement}"
        exit 1
    fi
done
for entitlement in \
    dynamic-codesigning \
    com.apple.security.cs.allow-jit \
    com.apple.security.cs.allow-unsigned-executable-memory; do
    if grep -q "<key>${entitlement}</key>" ${SIGNED_ENTITLEMENTS}; then
        print -u2 "Signed app contains TrollStore-incompatible entitlement: ${entitlement}"
        exit 1
    fi
done
cat ${SIGNED_ENTITLEMENTS}
xcrun vtool -show-build ${OUTPUT_DIR}/Payload/ARMSX3.app/ARMSX3
if otool -L ${OUTPUT_DIR}/Payload/ARMSX3.app/ARMSX3 | grep -E '/opt/homebrew|/usr/local|\.dylib' | grep -v '/usr/lib/'; then
    print -u2 "Unexpected non-system dynamic library dependency"
    exit 1
fi
shasum -a 256 "${IPA}" > "${IPA}.sha256"
print "IPA: ${IPA}"
