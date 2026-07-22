if(NOT PEONPAD_VISIONOS)
  message(FATAL_ERROR "PeonPadTabletop.cmake requires native visionOS.")
endif()

set(PEONPAD_TABLETOP_BUNDLE_IDENTIFIER "org.peonpad.tabletop"
  CACHE STRING "Bundle identifier for the native visionOS tabletop app")
if(PEONPAD_VISIONOS_SIMULATOR_BUILD)
  set(PEONPAD_TABLETOP_SUPPORTED_PLATFORM XRSimulator)
else()
  set(PEONPAD_TABLETOP_SUPPORTED_PLATFORM XROS)
endif()

add_executable(peonpad_tabletop MACOSX_BUNDLE
  platform/apple/visionos/tabletop/PeonPadTabletopApp.swift
  platform/apple/visionos/tabletop/TabletopBoardView.swift
  platform/apple/visionos/tabletop/TabletopGestureState.swift
)
target_link_libraries(peonpad_tabletop PRIVATE
  "-framework SwiftUI"
  "-framework RealityKit"
)
set_target_properties(peonpad_tabletop PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST
    "${CMAKE_CURRENT_LIST_DIR}/../platform/apple/visionos/tabletop/Info.plist.in"
  OUTPUT_NAME PeonPadTabletop
  Swift_LANGUAGE_VERSION 6
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
    "${PEONPAD_TABLETOP_BUNDLE_IDENTIFIER}"
  XCODE_ATTRIBUTE_SWIFT_VERSION 6.0
  XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY 7
)
if(PEONPAD_VISIONOS_ENABLE_SIGNING)
  set_target_properties(peonpad_tabletop PROPERTIES
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE Automatic
  )
endif()

add_custom_command(TARGET peonpad_tabletop POST_BUILD
  COMMAND
    "${CMAKE_CURRENT_LIST_DIR}/../platform/apple/visionos/compile-bundle-assets.sh"
    "${CMAKE_OSX_SYSROOT}"
    "${CMAKE_COMMAND}"
    "$<TARGET_BUNDLE_DIR:peonpad_tabletop>"
    "${CMAKE_CURRENT_LIST_DIR}/../platform/apple/visionos/PeonPadAssets.xcassets"
    "${CMAKE_CURRENT_LIST_DIR}/../platform/apple/ios/PeonPadAssets.xcassets/AppIcon.appiconset/PeonPadIcon.png"
    "${CMAKE_CURRENT_BINARY_DIR}/tabletop-assets"
  VERBATIM
)
