set(CMAKE_CXX_STANDARD 23)

set(ARMSX3_IOS_INPUT_SOURCES
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/pad_thread.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/product_info.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/ps_move_config.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/ps_move_tracker.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/mouse_gyro_handler.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/virtual_keyboard_handler.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/Input/virtual_pad_handler.cpp)

configure_file(Info.plist.in ${CMAKE_CURRENT_BINARY_DIR}/Info.plist @ONLY)

# Reuse Android's bundled controller skins verbatim. Keep the directory names in
# the app bundle so both frontends share the same asset naming contract.
set(ARMSX3_CONTROLLER_SKIN_ROOT
    ${CMAKE_SOURCE_DIR}/android/armsx3-ui/app/src/main/assets/controller_skins)
file(GLOB_RECURSE ARMSX3_CONTROLLER_SKIN_RESOURCES CONFIGURE_DEPENDS
    "${ARMSX3_CONTROLLER_SKIN_ROOT}/*.png")
foreach(skin_file IN LISTS ARMSX3_CONTROLLER_SKIN_RESOURCES)
    file(RELATIVE_PATH skin_rel "${ARMSX3_CONTROLLER_SKIN_ROOT}" "${skin_file}")
    get_filename_component(skin_dir "${skin_rel}" DIRECTORY)
    set_source_files_properties("${skin_file}" PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources/controller_skins/${skin_dir}")
endforeach()

# Reuse Android's cross-platform launcher media instead of maintaining a second
# copy with subtly different audio/video assets.
set(ARMSX3_ANDROID_APP_RAW ${CMAKE_SOURCE_DIR}/android/armsx3-app/app/src/main/res/raw)
set(ARMSX3_ANDROID_UI_RAW ${CMAKE_SOURCE_DIR}/android/armsx3-ui/app/src/main/res/raw)
set(ARMSX3_APP_MEDIA
    ${ARMSX3_ANDROID_APP_RAW}/library_music.m4a
    ${ARMSX3_ANDROID_APP_RAW}/pause_music.mp3
    ${ARMSX3_ANDROID_APP_RAW}/boot_intro.mp4
    ${ARMSX3_ANDROID_UI_RAW}/library_fallback.gif)
foreach(media_file IN LISTS ARMSX3_APP_MEDIA)
    set_source_files_properties("${media_file}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
endforeach()

set(ARMSX3_I18N_ROOT ${CMAKE_SOURCE_DIR}/android/armsx3-ui/app/src/main/assets/i18n)
file(GLOB ARMSX3_I18N_RESOURCES CONFIGURE_DEPENDS "${ARMSX3_I18N_ROOT}/*.json")
foreach(i18n_file IN LISTS ARMSX3_I18N_RESOURCES)
    set_source_files_properties("${i18n_file}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/i18n")
endforeach()

add_executable(ARMSX3 MACOSX_BUNDLE
    src/ARMSX3App.mm
    src/ARMSX3FrontendViewController.mm
    src/ARMSX3LibraryManagers.mm
    src/ARMSX3GameUpdatesViewController.mm
    src/ARMSX3FirmwareViewController.mm
    src/ARMSX3TrophiesViewController.mm
    src/ARMSX3OverlayArt.mm
    src/ARMSX3ShaderChainViewController.mm
    src/ARMSX3SkinManager.mm
    src/ARMSX3RPCNViewController.mm
    src/ARMSX3LibraryMetadata.mm
    src/ARMSX3NewsViewController.mm
    src/ARMSX3AboutViewController.mm
    src/ARMSX3OnboardingViewController.mm
    src/ARMSX3AppPreferences.mm
    src/ARMSX3AppSettingsViewController.mm
    src/ARMSX3Updater.mm
    src/ARMSX3SecondScreen.mm
    src/ARMSX3RumbleBridge.mm
    src/ARMSX3EmulationMenuViewController.mm
    src/ARMSX3SettingsViewController.mm
    src/ARMSX3TouchControls.mm
    src/ARMSX3Localization.mm
    src/ARMSX3ControllerMappings.mm
    src/ARMSX3IOSAudioBackend.mm
    src/armsx3_ios_core.mm
    ${CMAKE_SOURCE_DIR}/3rdparty/zlib/zlib/contrib/minizip/zip.c
    ${CMAKE_SOURCE_DIR}/3rdparty/zlib/zlib/contrib/minizip/ioapi.c
    ${ARMSX3_IOS_INPUT_SOURCES}
    ${CMAKE_SOURCE_DIR}/rpcs3/dev/iso.cpp
    ${CMAKE_SOURCE_DIR}/rpcs3/rpcs3_version.cpp
    ${ARMSX3_CONTROLLER_SKIN_RESOURCES}
    ${ARMSX3_I18N_RESOURCES}
    ${ARMSX3_APP_MEDIA}
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
    ${CMAKE_SOURCE_DIR}/3rdparty/zlib/zlib
    ${CMAKE_SOURCE_DIR}/3rdparty/zlib/zlib/contrib/minizip
    ${CMAKE_SOURCE_DIR}/3rdparty/yaml-cpp/yaml-cpp/include)

target_link_libraries(ARMSX3 PRIVATE
    rpcs3_emu
    3rdparty::zlib
    3rdparty::fusion
    3rdparty::libusb
    "-framework UIKit"
    "-framework Foundation"
    "-framework QuartzCore"
    "-framework ImageIO"
    "-framework Metal"
    "-framework GameController"
    "-framework CoreMotion"
    "-framework UniformTypeIdentifiers"
    "-framework AVFoundation"
    "-framework AudioToolbox"
    "-framework CoreAudio"
    "-framework CoreHaptics")

set_source_files_properties(Assets.xcassets PROPERTIES
    MACOSX_PACKAGE_LOCATION Resources)

set_target_properties(ARMSX3 PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_BINARY_DIR}/Info.plist
    MACOSX_BUNDLE_BUNDLE_NAME ARMSX3
    MACOSX_BUNDLE_GUI_IDENTIFIER com.armsx3.ios
    MACOSX_BUNDLE_SHORT_VERSION_STRING 0.9.9
    MACOSX_BUNDLE_BUNDLE_VERSION 116
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
    XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "iphoneos iphonesimulator"
    XCODE_ATTRIBUTE_SUPPORTS_MACCATALYST NO
    XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/Frameworks")

install(TARGETS ARMSX3 BUNDLE DESTINATION .)
