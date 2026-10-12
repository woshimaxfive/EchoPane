# Build the ASR runtime without TTS (and its GPL phonemizer dependencies).
# The public Dart bindings are reused, but their full bundled DLL is not shipped.
set(SHERPA_REVISION "11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf")
set(SHERPA_ROOT "${AUDIO_DEPS}/sherpa-onnx-${SHERPA_REVISION}")
if(NOT EXISTS "${SHERPA_ROOT}/CMakeLists.txt")
  audio_download(sherpa-asr.zip "https://codeload.github.com/k2-fsa/sherpa-onnx/zip/${SHERPA_REVISION}"
    1e546178d875fae6e74ffd9aa15a13546b9a4a13d0c90c60524ca5022a113edf)
  execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${AUDIO_DEPS}/sherpa-asr.zip"
    WORKING_DIRECTORY "${AUDIO_DEPS}" RESULT_VARIABLE extracted)
  if(NOT extracted EQUAL 0)
    message(FATAL_ERROR "Could not extract sherpa-onnx")
  endif()
endif()

set(BUILD_SHARED_LIBS ON)
set(SHERPA_ONNX_ENABLE_TTS OFF CACHE BOOL "" FORCE)
set(SHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION OFF CACHE BOOL "" FORCE)
set(SHERPA_ONNX_ENABLE_PORTAUDIO OFF CACHE BOOL "" FORCE)
set(SHERPA_ONNX_ENABLE_WEBSOCKET OFF CACHE BOOL "" FORCE)
set(SHERPA_ONNX_ENABLE_BINARY OFF CACHE BOOL "" FORCE)
set(SHERPA_ONNX_BUILD_C_API_EXAMPLES OFF CACHE BOOL "" FORCE)
set(location_onnxruntime_header_dir "${ORT_ROOT}/include")
set(location_onnxruntime_lib "${ORT_ROOT}/lib/onnxruntime.lib")
set(location_onnxruntime_lib2 "${ORT_ROOT}/lib/onnxruntime.lib")
include_directories("${ORT_ROOT}/include")
add_subdirectory("${SHERPA_ROOT}" "${CMAKE_BINARY_DIR}/streaming-asr" EXCLUDE_FROM_ALL)
target_compile_options(sherpa-onnx-core PRIVATE "$<$<CONFIG:Release>:/MP4>")
add_dependencies(${BINARY_NAME} sherpa-onnx-c-api)
set(STREAMING_RUNTIME_LIBRARIES "$<TARGET_FILE:sherpa-onnx-c-api>" PARENT_SCOPE)
