cmake_minimum_required(VERSION 3.20)
project(XmlNavigator LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)

set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "" FORCE)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

set(NPP_MACOS_DIR "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(SCINTILLA_INCLUDE "${NPP_MACOS_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

add_library(XmlNavigator SHARED src/XmlNavigator.mm)
target_include_directories(XmlNavigator PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE})
# ARC so XNNode lifetimes are automatic — without it we leaked the whole
# tree on every reload (alloc + addObject = rc 2, never released).
target_compile_options(XmlNavigator PRIVATE -fobjc-arc)
target_link_libraries(XmlNavigator PRIVATE "-framework Cocoa")
set_target_properties(XmlNavigator PROPERTIES PREFIX "" SUFFIX ".dylib")

set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.notepad++/plugins/XmlNavigator")
install(TARGETS XmlNavigator DESTINATION "${PLUGIN_INSTALL_DIR}")
# Toolbar icons land at the plugin root (not inside resources/) because
# the source code passes "toolbar.png" verbatim to NPPM_ADDTOOLBARICON_-
# FORDARKMODE, and that path is resolved relative to the plugin's install
# directory. Both light and dark variants are installed; the host picks
# the matching one based on macOS appearance.
install(FILES resources/toolbar.png resources/toolbar_dark.png
        DESTINATION "${PLUGIN_INSTALL_DIR}")
