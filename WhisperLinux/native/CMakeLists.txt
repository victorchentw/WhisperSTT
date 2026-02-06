cmake_minimum_required(VERSION 3.16)
project(whisper_linux_cli LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(WHISPER_CPP_DIR "" CACHE PATH "Path to whisper.cpp")

if (NOT WHISPER_CPP_DIR)
    message(FATAL_ERROR "WHISPER_CPP_DIR is required (path to whisper.cpp)")
endif()

set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)

set(MODEL_PATH "${CMAKE_CURRENT_LIST_DIR}/../models/ggml-tiny.bin")
set(MODEL_HEADER "${CMAKE_BINARY_DIR}/model_data.h")

add_custom_command(
    OUTPUT ${MODEL_HEADER}
    COMMAND xxd -i -n whisper_model ${MODEL_PATH} > ${MODEL_HEADER}
    DEPENDS ${MODEL_PATH}
    VERBATIM
)

add_custom_target(model_header DEPENDS ${MODEL_HEADER})

add_subdirectory(${WHISPER_CPP_DIR} whispercpp)

add_executable(whisper_cli whisper_cli.cpp ${MODEL_HEADER})
add_dependencies(whisper_cli model_header)

target_include_directories(whisper_cli PRIVATE ${CMAKE_BINARY_DIR} ${WHISPER_CPP_DIR})

target_link_libraries(whisper_cli PRIVATE whisper)
