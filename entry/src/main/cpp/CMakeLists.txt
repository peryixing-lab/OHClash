cmake_minimum_required(VERSION 3.5.0)
project(flclash_napi)

add_library(flclash_core SHARED IMPORTED)
set_target_properties(flclash_core PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libflclash_core.so
    IMPORTED_NO_SONAME TRUE)

add_library(flclash_napi SHARED napi_init.c)
target_include_directories(flclash_napi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${OHOS_ARCH})
target_link_libraries(flclash_napi PUBLIC libace_napi.z.so flclash_core)
set_target_properties(flclash_napi PROPERTIES
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "$ORIGIN")
