#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
SOURCE_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${ARMSX3_IOS_BUILD_DIR:-${SOURCE_DIR}/build/ios-simulator}
DEVICE=${1:-booted}
FIRMWARE=${2:-${HOME}/Downloads/PS3UPDAT.PUP}
APP=${BUILD_DIR}/bin/ARMSX3.app
BUNDLE_ID=com.armsx3.ios

if [[ ! -d ${APP} ]]; then
    print -u2 "Missing simulator app. Run zsh ios/build-simulator.sh first."
    exit 1
fi
if [[ ! -f ${FIRMWARE} ]]; then
    print -u2 "Firmware file not found: ${FIRMWARE}"
    exit 1
fi

xcrun simctl bootstatus ${DEVICE} -b
xcrun simctl install ${DEVICE} ${APP}
CONTAINER=$(xcrun simctl get_app_container ${DEVICE} ${BUNDLE_ID} data)
mkdir -p "${CONTAINER}/Documents/Firmware"
cp "${FIRMWARE}" "${CONTAINER}/Documents/Firmware/PS3UPDAT.PUP"
: > "${BUILD_DIR}/simulator.stdout.log"
: > "${BUILD_DIR}/simulator.stderr.log"
SIMCTL_CHILD_ARMSX3_SIMULATOR_FIRMWARE="${CONTAINER}/Documents/Firmware/PS3UPDAT.PUP" \
    xcrun simctl launch --terminate-running-process \
        --stdout="${BUILD_DIR}/simulator.stdout.log" \
        --stderr="${BUILD_DIR}/simulator.stderr.log" \
        ${DEVICE} ${BUNDLE_ID}
print "App data: ${CONTAINER}"
print "Logs: ${CONTAINER}/Documents/Logs"
print "Console: ${BUILD_DIR}/simulator.stderr.log"
