# Official native distributions, pinned and verified before extraction.
set(OCR_DEPS "$ENV{ECHOPANE_OCR_DEPS}")
if(NOT OCR_DEPS)
  set(OCR_DEPS "${CMAKE_BINARY_DIR}/ocr-deps")
endif()
file(TO_CMAKE_PATH "${OCR_DEPS}" OCR_DEPS)
file(MAKE_DIRECTORY "${OCR_DEPS}")
function(ocr_download name url hash)
  set(destination "${OCR_DEPS}/${name}")
  if(EXISTS "${destination}")
    file(SHA256 "${destination}" actual_hash)
  endif()
  if(NOT actual_hash STREQUAL hash)
    file(DOWNLOAD "${url}" "${destination}" EXPECTED_HASH "SHA256=${hash}"
      TLS_VERIFY ON SHOW_PROGRESS STATUS download_status)
    list(GET download_status 0 code)
    if(NOT code EQUAL 0)
      message(FATAL_ERROR "Could not download ${name}: ${download_status}")
    endif()
  endif()
endfunction()
set(ORT_ROOT "${OCR_DEPS}/onnxruntime-win-x64-1.30.0")
if(NOT EXISTS "${ORT_ROOT}/include/onnxruntime_cxx_api.h")
  ocr_download(ort.zip "https://github.com/microsoft/onnxruntime/releases/download/v1.30.0/onnxruntime-win-x64-1.30.0.zip"
    c6ba983baf5681af108599675d2a89c2d145512d02de28aed0bff177cd0ba949)
  execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xvf "${OCR_DEPS}/ort.zip"
    WORKING_DIRECTORY "${OCR_DEPS}" RESULT_VARIABLE extracted OUTPUT_QUIET)
  if(NOT extracted EQUAL 0)
    message(FATAL_ERROR "Could not extract ONNX Runtime")
  endif()
endif()
set(OPENCV_ROOT "${OCR_DEPS}/opencv/build")
if(NOT EXISTS "${OPENCV_ROOT}/include/opencv2/core.hpp")
  ocr_download(opencv.exe "https://github.com/opencv/opencv/releases/download/4.13.0/opencv-4.13.0-windows.exe"
    f0e98c302464d6860777a7015065e11b9b271b5394e6ba92663f0cf1fc303f2c)
  execute_process(COMMAND "${OCR_DEPS}/opencv.exe" -y "-o${OCR_DEPS}"
    RESULT_VARIABLE extracted OUTPUT_QUIET)
  if(NOT extracted EQUAL 0)
    message(FATAL_ERROR "Could not extract OpenCV")
  endif()
endif()
set(RAPIDOCR_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../third_party/rapidocr")
add_library(echopane_rapidocr STATIC
  "${RAPIDOCR_ROOT}/src/AngleNet.cpp" "${RAPIDOCR_ROOT}/src/CrnnNet.cpp"
  "${RAPIDOCR_ROOT}/src/DbNet.cpp" "${RAPIDOCR_ROOT}/src/OcrLite.cpp"
  "${RAPIDOCR_ROOT}/src/OcrLiteImpl.cpp" "${RAPIDOCR_ROOT}/src/OcrUtils.cpp"
  "${RAPIDOCR_ROOT}/src/clipper.cpp")
target_compile_features(echopane_rapidocr PRIVATE cxx_std_17)
target_compile_options(echopane_rapidocr PRIVATE /utf-8 /wd4996 /wd4267)
target_compile_definitions(echopane_rapidocr PRIVATE NOMINMAX _CRT_SECURE_NO_WARNINGS)
target_include_directories(echopane_rapidocr PUBLIC "${RAPIDOCR_ROOT}/include")
target_include_directories(echopane_rapidocr SYSTEM PUBLIC "${ORT_ROOT}/include" "${OPENCV_ROOT}/include")
target_link_libraries(echopane_rapidocr PUBLIC "${ORT_ROOT}/lib/onnxruntime.lib"
  "$<$<CONFIG:Debug>:${OPENCV_ROOT}/x64/vc16/lib/opencv_world4130d.lib>"
  "$<$<NOT:$<CONFIG:Debug>>:${OPENCV_ROOT}/x64/vc16/lib/opencv_world4130.lib>")
set(OCR_RUNTIME_LIBRARIES "${ORT_ROOT}/lib/onnxruntime.dll"
  "${ORT_ROOT}/lib/onnxruntime_providers_shared.dll"
  "$<$<CONFIG:Debug>:${OPENCV_ROOT}/x64/vc16/bin/opencv_world4130d.dll>"
  "$<$<NOT:$<CONFIG:Debug>>:${OPENCV_ROOT}/x64/vc16/bin/opencv_world4130.dll>" PARENT_SCOPE)
