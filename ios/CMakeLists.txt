set(CMAKE_CXX_STANDARD 23)

set(ARMSX3_IOS_INPUT_SOURCES
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/pad_thread.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/product_info.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/ps_move_config.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/ps_move_tracker.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/mouse_gyro_handler.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/virtual_pad_handler.cpp)

configure_file(Info.plist.in ${CMAKE_CURRENT_BINARY_DIR}/Info.plist @ONLY)

add_executable(ARMSX3 MACOSX_BUNDLE
    src/ARMSX3App.mm
    src/ARMSX3FrontendViewController.mm
    src/ARMSX3EmulationMenuViewController.mm
    src/ARMSX3SettingsViewController.mm
    src/armsx3_ios_core.mm
    ${ARMSX3_IOS_INPUT_SOURCES}
    ${CMAKE_SOURCE_DIR}/rpcs3/dev/iso.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/rpcs3_version.cpp
    Assets.xcassets)

target_compile_definitions(ARMSX3 PRIVATE ARMSX3_IOS=1)
target_compile_features(ARMSX3 PRIVATE cxx_std_23)

set(ARMSX3_IOS_JIT_COMPAT
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-include${CMAKE_CURRENT_SOURCE_DIR}/src/jit_compat.h>")
target_compile_options(ARMSX3 PRIVATE ${ARMSX3_IOS_JIT_COMPAT})
target_compile_options(rpcs3_emu PRIVATE ${ARMSX3_IOS_JIT_COMPAT})
target_compile_options(asmjit PRIVATE ${ARMSX3_IOS_JIT_COMPAT})
target_include_directories(ARMSX3 PRIVATE
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/rpcs3
    ${CMAKE_SOURCE_DIR}/3rdparty/libusb/libusb/libusb
    ${CMAKE_SOURCE_DIR}/3rdparty/yaml-cpp/yaml-cpp/include)

target_include_directories(rpcs3_emu PRIVATE
    ${CMAKE_SOURCE_DIR}/3rdparty/librashader/include)

target_link_libraries(ARMSX3 PRIVATE
    rpcs3_emu
    3rdparty::fusion
    3rdparty::libusb
    "-framework UIKit"
    "-framework Foundation"
    "-framework QuartzCore"
    "-framework Metal"
    "-framework GameController"
    "-framework UniformTypeIdentifiers"
    "-framework AVFoundation"
    "-framework CoreHaptics")

set_source_files_properties(Assets.xcassets PROPERTIES
    MACOSX_PACKAGE_LOCATION Resources)

set_target_properties(ARMSX3 PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_BINARY_DIR}/Info.plist
    MACOSX_BUNDLE_BUNDLE_NAME ARMSX3
    MACOSX_BUNDLE_GUI_IDENTIFIER com.armsx3.ios
    MACOSX_BUNDLE_SHORT_VERSION_STRING 0.9.9
    MACOSX_BUNDLE_BUNDLE_VERSION 7
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER com.armsx3.ios
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET 15.0
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME AppIcon
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
    XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
    XCODE_ATTRIBUTE_ENABLE_BITCODE NO
    XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH YES
    XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS iphoneos
    XCODE_ATTRIBUTE_SUPPORTS_MACCATALYST NO
    XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/Frameworks")

install(TARGETS ARMSX3 BUNDLE DESTINATION .)
