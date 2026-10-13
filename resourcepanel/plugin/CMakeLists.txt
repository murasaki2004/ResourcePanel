cmake_minimum_required(VERSION 3.21)
project(ResourcePanel VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Qml Quick)

# A plain QML extension plugin. Deliberately avoids qt_add_qml_module so the
# build needs no qmlcachegen/qmllint and the installed module layout stays
# explicit and easy to remove again.
add_library(resourcepanel MODULE
    src/telemetry.cpp
    src/resourcepanel_plugin.cpp
)
target_link_libraries(resourcepanel PRIVATE Qt6::Core Qt6::Qml Qt6::Quick)

# QML import path discovered at configure time (e.g. /usr/lib/qt6/qml).
# Override with -DRESOURCEPANEL_QML_DIR=... to install elsewhere.
if(NOT DEFINED RESOURCEPANEL_QML_DIR)
    # qmake is the supported way to ask Qt where its QML modules live.
    find_program(QMAKE6_EXECUTABLE NAMES qmake6 qmake)
    if(QMAKE6_EXECUTABLE)
        execute_process(
            COMMAND ${QMAKE6_EXECUTABLE} -query QT_INSTALL_QML
            OUTPUT_STRIP_TRAILING_WHITESPACE
            OUTPUT_VARIABLE RESOURCEPANEL_QML_DIR
        )
    endif()
    if(NOT RESOURCEPANEL_QML_DIR)
        set(RESOURCEPANEL_QML_DIR "${CMAKE_INSTALL_PREFIX}/lib/qt6/qml")
    endif()
endif()

message(STATUS "ResourcePanel QML module install dir: ${RESOURCEPANEL_QML_DIR}")

# The module URI is org.murasaki.resourcepanel, so the directory layout has to
# mirror it exactly: Qt resolves the import by walking the dotted path.
set(RESOURCEPANEL_MODULE_SUBDIR "org/murasaki/resourcepanel")

install(TARGETS resourcepanel
        LIBRARY DESTINATION "${RESOURCEPANEL_QML_DIR}/${RESOURCEPANEL_MODULE_SUBDIR}")
install(FILES qmlmodule/qmldir
        DESTINATION "${RESOURCEPANEL_QML_DIR}/${RESOURCEPANEL_MODULE_SUBDIR}")

# `make uninstall` support: removes exactly the files this project installed.
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake_uninstall.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/cmake_uninstall.cmake"
    IMMEDIATE @ONLY
)
add_custom_target(uninstall
    COMMAND ${CMAKE_COMMAND} -P "${CMAKE_CURRENT_BINARY_DIR}/cmake_uninstall.cmake"
    COMMENT "Removing installed ResourcePanel QML plugin"
)
