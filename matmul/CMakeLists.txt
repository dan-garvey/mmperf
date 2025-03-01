cmake_minimum_required(VERSION 3.18)
project(matmul C CXX)

set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CMAKE_CURRENT_LIST_DIR}/../cmake/")
include(common)

# Matrix sizes to benchmark
message(STATUS "Reading matrix sizes from ... ${SIZE_FILE}")
file(READ ${SIZE_FILE} MATRIX_SIZES)
string(REGEX REPLACE "#[^\n]*\n" "" MATRIX_SIZES "${MATRIX_SIZES}")
string(REGEX REPLACE ";" "\\\\;" MATRIX_SIZES "${MATRIX_SIZES}")
string(REGEX REPLACE "\n" ";" MATRIX_SIZES "${MATRIX_SIZES}")

# Read tile sizes from file for iree-llvm-sandbox
if(USE_IREE_LLVM_SANDBOX)
  file(READ ${SANDBOX_TILE_FILE} SANDBOX_TILE_SIZES)
  string(REGEX REPLACE "#[^\n]*\n" "" SANDBOX_TILE_SIZES "${SANDBOX_TILE_SIZES}")
  string(REGEX REPLACE ";" "\\\\;" SANDBOX_TILE_SIZES "${SANDBOX_TILE_SIZES}")
  string(REGEX REPLACE "\n" ";" SANDBOX_TILE_SIZES "${SANDBOX_TILE_SIZES}")

  set(SANDBOX_TILE_SIZES_FILE_LINE_COUNTER 0)
endif()

if(USE_NODAI)
  message(STATUS "Reading tile sizes from ... ${TILE_FILE}")
  file(READ "${TILE_FILE}" TILE_SIZE_LIST)
  string(REGEX REPLACE "#[^\n]*\n" "" TILE_SIZE_LIST "${TILE_SIZE_LIST}")
  string(REGEX REPLACE ";" "\\\\;" TILE_SIZE_LIST "${TILE_SIZE_LIST}")
  string(REGEX REPLACE "\n" ";" TILE_SIZE_LIST "${TILE_SIZE_LIST}")
  if(NOT SEARCH_MODE)
    foreach(TILE_SIZE IN LISTS TILE_SIZE_LIST)
      if (TILE_SIZE)
        string(REPLACE "," ";" pair ${TILE_SIZE})
        list(GET pair 0 matrix_size)
        list(GET pair 1 tile_size)
        list(GET pair 2 register_size)
        list(GET pair 3 copy_size)
        string(REPLACE "x" " " "TILE_FOR_MATRIX_${matrix_size}" "${tile_size}")
        string(REPLACE "x" " " "REGISTER_FOR_MATRIX_${matrix_size}" "${register_size}")
        string(REPLACE "x" " " "COPY_FILL_FOR_MATRIX_${matrix_size}" "${copy_size}")
        message(STATUS "Matrix ${matrix_size} has tile size ${tile_size}")
      endif()
    endforeach()
  endif()
endif()

if(USE_MLIR OR USE_NODAI OR USE_MLIR_CUDA)
  function(compile_mlir mlir_prefix M N K nodai_mode mlircuda_mode)
    set(OBJ ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.o)
    if(nodai_mode)
      if(NOT DEFINED "TILE_FOR_MATRIX_${M}x${N}x${K}")
        message(FATAL_ERROR "A tile size for ${M}x${N}x${K} wasn't provided in ${TILE_FILE}")
      endif()
      message(STATUS "Using nodai tiles sizes ...")
      set(TILE_SIZES_LOCAL ${TILE_FOR_MATRIX_${M}x${N}x${K}})
      set(REGISTER_TILE_SIZES_LOCAL ${REGISTER_FOR_MATRIX_${M}x${N}x${K}})
      set(COPY_FILL_TILE_SIZES_LOCAL ${COPY_FILL_FOR_MATRIX_${M}x${N}x${K}})
      set(COL_MAJOR_TILE_SIZES "16 0 32")
    else()
      if("${TILE_SIZES}" STREQUAL "")
        message(STATUS "Using default tile sizes")
        if(M GREATER 1000)
          set(TILE_SIZES_LOCAL "128 128 256")
          set(REGISTER_TILE_SIZES_LOCAL "8 16 8")
          set(COPY_FILL_TILE_SIZES_LOCAL "4 16")
          set(COL_MAJOR_TILE_SIZES "16 0 32")
        else()
          set(TILE_SIZES_LOCAL "12 32 16")
          set(REGISTER_TILE_SIZES_LOCAL "")
          set(COPY_FILL_TILE_SIZES_LOCAL "4 16")
          set(COL_MAJOR_TILE_SIZES "16 0 32")
        endif()
      else()
        set(TILE_SIZES_LOCAL "${TILE_SIZES}")
        set(REGISTER_TILE_SIZES_LOCAL "${REGISTER_TILE_SIZES}")
        set(COPY_FILL_TILE_SIZES_LOCAL "${COPY_FILL_TILE_SIZES}")
        message(STATUS "Using custom tile sizes ...")
      endif()
    endif()
    message(STATUS "Tile sizes = ${TILE_SIZES_LOCAL}")
    message(STATUS "Register Tile sizes = ${REGISTER_TILE_SIZES_LOCAL}")
    message(STATUS "Copy Fill Tile sizes = ${COPY_FILL_TILE_SIZES_LOCAL}")
    if(${USE_COLUMN_MAJOR} STREQUAL "ON")
      message(STATUS "Compiling linalg.matmul_column_major ...")
      configure_file(${CMAKE_SOURCE_DIR}/matmul_column_major_mlir_MxNxK.mlir.in ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.mlir)
    else()
      if(mlircuda_mode)
        message(STATUS "Compiling linalg.matmul with CUDA backend ...")
        configure_file(${CMAKE_SOURCE_DIR}/matmul_mlircuda_MxNxK.mlir.in ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.mlir)
      else()
        message(STATUS "Compiling linalg.matmul ...")
        configure_file(${CMAKE_SOURCE_DIR}/matmul_mlir_MxNxK.mlir.in ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.mlir)
      endif()
    endif()
    # For larger sizes, we will still use matmul-compile
    if((${USE_MATMUL_COMPILE} STREQUAL "ON") OR (M GREATER 1000))
      add_custom_command(OUTPUT ${OBJ}
        COMMAND ${CMAKE_BINARY_DIR}/matmul-compile/matmul-compile
        -M=${M} -N=${N} -K=${K} -target-cpu=${TARGET_CPU} -vector-width=${VECTOR_WIDTH}
        -tile-sizes=${TILE_SIZES_LOCAL} -register-tile-sizes=${REGISTER_TILE_SIZES_LOCAL}
        -copy-fill-tile-sizes=${COPY_FILL_TILE_SIZES_LOCAL}
        -promote=true -promote-full-tile-pad=true -vectorize=true
        -vectorize-to=outerproduct -split-vector-transfers-to=vector-transfers
        -unroll-vector-transfers=true
        ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.mlir
        COMMAND ${CMAKE_CXX_COMPILER} -Ofast ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.ll
        -mllvm -enable-matrix -mllvm -matrix-allow-contract -mllvm -matrix-default-layout=row-major
        -c -o ${OBJ} -g
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/mlir-objs
        DEPENDS matmul-compile)
    else()
      string(REPLACE " " "," TILE_SIZES_LOCAL "${TILE_SIZES_LOCAL}")
      string(REPLACE " " "," COL_MAJOR_TILE_SIZES "${COL_MAJOR_TILE_SIZES}")
      string(REPLACE " " "," COPY_FILL_TILE_SIZES_LOCAL "${COPY_FILL_TILE_SIZES_LOCAL}")
      if (DEFINED PREBUILT_LLVM_PATH AND (NOT PREBUILT_LLVM_PATH STREQUAL ""))
        set(MLIR_OPT ${PREBUILT_LLVM_PATH}/bin/mlir-opt)
        set(MLIR_TRANSLATE ${PREBUILT_LLVM_PATH}/bin/mlir-translate)
      else()
        set(MLIR_OPT ${CMAKE_BINARY_DIR}/../mlir-install/bin/mlir-opt)
        set(MLIR_TRANSLATE ${CMAKE_BINARY_DIR}/../mlir-install/bin/mlir-translate)
      endif()
      if(mlircuda_mode)
        add_custom_command(
          OUTPUT ${OBJ}
          COMMAND cat ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.mlir |
          ${MLIR_OPT} --linalg-tile-to-parallel-loops=\"linalg-tile-sizes=${TILE_SIZES_LOCAL}\" |
          ${MLIR_OPT} --convert-linalg-to-parallel-loops --test-gpu-greedy-parallel-loop-mapping |
          ${MLIR_OPT} --convert-parallel-loops-to-gpu --gpu-kernel-outlining --lower-affine |
          ${MLIR_OPT} --convert-scf-to-std --canonicalize |
          ${MLIR_OPT} --pass-pipeline=\"gpu.module\(strip-debuginfo, convert-gpu-to-nvvm, gpu-to-cubin\)\" --gpu-to-llvm |
          ${MLIR_TRANSLATE} --mlir-to-llvmir | opt -O3 -S | llc -O3 | as - -o ${OBJ}
          WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/mlir-objs)
      else()
        add_custom_command(OUTPUT ${OBJ}
          COMMAND cat ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.mlir |
          ${MLIR_OPT} -test-linalg-codegen-strategy=\"anchor-func=matmul anchor-op=linalg.matmul_column_major register-tile-sizes=${COL_MAJOR_TILE_SIZES} vectorize\" |
          ${MLIR_OPT} -test-linalg-codegen-strategy=\"anchor-func=matmul anchor-op=linalg.matmul register-tile-sizes=${TILE_SIZES_LOCAL} vectorize\" |
          ${MLIR_OPT} -test-linalg-codegen-strategy=\"anchor-op=linalg.fill register-tile-sizes=${COPY_FILL_TILE_SIZES_LOCAL} vectorize\" |
          ${MLIR_OPT} -test-linalg-codegen-strategy=\"anchor-op=linalg.copy register-tile-sizes=${COPY_FILL_TILE_SIZES_LOCAL} vectorize\" |
          ${MLIR_OPT} -linalg-comprehensive-module-bufferize -convert-vector-to-scf -lower-affine -convert-linalg-to-loops -canonicalize -convert-scf-to-std -lower-affine -convert-vector-to-llvm -convert-memref-to-llvm -convert-std-to-llvm |
          ${MLIR_TRANSLATE} --mlir-to-llvmir -o=${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.ll
          COMMAND ${CMAKE_CXX_COMPILER} -Ofast ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.ll
          -mllvm -enable-matrix -mllvm -matrix-allow-contract -mllvm -matrix-default-layout=row-major
          -c -o ${OBJ} -g
          WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/mlir-objs)
      endif()
    endif()
  endfunction()

  add_subdirectory(matmul-compile)
endif()

function(compile_llvm_sandbox_mlir mlir_prefix M N K)

  set(OBJ ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.o)

  set(MLIR_OPT ${CMAKE_BINARY_DIR}/../mlir/bin/mlir-opt)
  set(MLIR_PROTO_OPT ${CMAKE_BINARY_DIR}/../mlir/bin/mlir-proto-opt)
  set(MLIR_TRANSLATE ${CMAKE_BINARY_DIR}/../mlir/bin/mlir-translate)

  configure_file(${CMAKE_SOURCE_DIR}/matmul_llvmsandbox_MxNxK.mlir ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.mlir)

  add_custom_command(
    OUTPUT ${OBJ}
    COMMAND cat ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.mlir |
    ${MLIR_PROTO_OPT} -canonicalize -mlir-disable-threading -linalg-tensor-codegen-strategy=\"anchor-func=matmul anchor-op=linalg.matmul distribute distribute-tile-sizes=${FIRST_TILE_SIZE}\" | 
    ${MLIR_PROTO_OPT} -linalg-tensor-codegen-strategy=\"anchor-func=matmul anchor-op=linalg.matmul distribute distribute-tile-sizes=${SECOND_TILE_SIZE}\" | 
    ${MLIR_PROTO_OPT} -linalg-tensor-codegen-strategy=\"anchor-func=matmul anchor-op=linalg.matmul tile-sizes=${THIRD_TILE_SIZE} vectorize\" | 
    ${MLIR_PROTO_OPT} -linalg-tensor-codegen-strategy=\"anchor-func=matmul anchor-op=linalg.fill vectorize\" | 
    ${MLIR_OPT} --linalg-comprehensive-module-bufferize |
    ${MLIR_OPT} -fold-memref-subview-ops -canonicalize |
    ${MLIR_PROTO_OPT} -canonicalize -linalg-tensor-codegen-strategy=\"convert-to-gpu num-gpu-workgrpoups=2,2 distribute-to-gpu-ids tiled-loop-to-scf\" | 
    ${MLIR_OPT} -convert-vector-to-scf=full-unroll=true -convert-linalg-to-loops | 
    ${MLIR_OPT} -gpu-kernel-outlining | 
    ${MLIR_OPT} -lower-affine -convert-scf-to-std |
    ${MLIR_OPT} -convert-vector-to-llvm -convert-memref-to-llvm -canonicalize -cse |
    ${MLIR_OPT} -pass-pipeline=\"gpu.module\(strip-debuginfo,convert-gpu-to-nvvm,canonicalize,gpu-to-cubin\)\" -gpu-to-llvm |
    ${MLIR_TRANSLATE} --mlir-to-llvmir -o=${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.ll
    COMMAND ${CMAKE_CXX_COMPILER} -Ofast ${CMAKE_BINARY_DIR}/mlir-objs/${mlir_prefix}.ll
    -c -o ${OBJ}
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/mlir-objs)
  
endfunction()

if(${USE_HALIDE} STREQUAL "ON")
  list(APPEND CMAKE_PREFIX_PATH ${HALIDE_DIR}/lib/cmake/Halide)
  add_subdirectory(halide)
endif()

if(${USE_RUY} STREQUAL "ON")
  add_subdirectory(${RUY_SOURCE} ruy)
endif()

if(${USE_CUBLAS} STREQUAL "ON" OR ${USE_MLIR_CUDA} STREQUAL "ON")
  find_package(CUDA REQUIRED)
endif()

# Number of times to repeat the test
set(NUM_REPS ${NUM_REPS})

set(BACKENDS "")
if(SEARCH_MODE)
  message(STATUS "Some backends might be ignored because search mode is enabled.")
  set(MATRIX_SIZES "${TILE_SIZE_LIST}")
else()
  if(USE_ACCELERATE)
    list(APPEND BACKENDS accelerate)
  endif()
  if(USE_BLASFEO)
    list(APPEND BACKENDS blasfeo)
  endif()
  if(USE_BLIS)
    list(APPEND BACKENDS blis)
  endif()
  if(USE_CUBLAS)
    list(APPEND BACKENDS cublas)
  endif()
  if(USE_HALIDE)
    list(APPEND BACKENDS halide)
  endif()
  if(USE_MKL)
    list(APPEND BACKENDS mkl)
  endif()
  if(USE_MLIR)
    list(APPEND BACKENDS mlir)
  endif()
  if(USE_MLIR_CUDA)
    list(APPEND BACKENDS mlircuda)
  endif()
  if(USE_NAIVE)
    list(APPEND BACKENDS naive)
  endif()
  if(USE_OPENBLAS)
    list(APPEND BACKENDS openblas)
  endif()
  if(USE_RUY)
    list(APPEND BACKENDS ruy)
  endif()
  if(USE_TVM)
    list(APPEND BACKENDS tvm)
  endif()
endif()
if(USE_NODAI OR SEARCH_MODE)
  list(APPEND BACKENDS nodai)
endif()
if(USE_IREE_LLVM_SANDBOX)
  list(APPEND BACKENDS ireellvmsandbox)
endif()

# Create executables for each size and one for all
set(ALL_TARGETS "")
foreach(BACKEND ${BACKENDS})
  foreach(MATRIX_SIZE ${MATRIX_SIZES})
    if ("${MATRIX_SIZE}" STREQUAL "")
      continue()
    endif()
    set(SRC main.cc)

    if(SEARCH_MODE)
      string(REPLACE "," ";" SEARCH_PARAMS ${MATRIX_SIZE})
      list(GET SEARCH_PARAMS 0 MATRIX_SIZE)
      list(GET SEARCH_PARAMS 1 tile_size)
      list(GET SEARCH_PARAMS 2 register_size)
      list(GET SEARCH_PARAMS 3 copy_size)
      string(REPLACE "x" " " "TILE_FOR_MATRIX_${MATRIX_SIZE}" "${tile_size}")
      string(REPLACE "x" " " "REGISTER_FOR_MATRIX_${MATRIX_SIZE}" "${register_size}")
      string(REPLACE "x" " " "COPY_FILL_FOR_MATRIX_${MATRIX_SIZE}" "${copy_size}")
      string(CONCAT MATMUL "matmul_" ${BACKEND} "_m" ${MATRIX_SIZE} "_t" "${tile_size}" "_r" "${register_size}" "_c" "${copy_size}")
    else()
      string(CONCAT MATMUL "matmul_" ${BACKEND} "_" ${MATRIX_SIZE})
    endif()

    message(STATUS "Compiling ${MATMUL}")

    string(REPLACE "x" ";" SIZES ${MATRIX_SIZE})
    list(GET SIZES 0 M)
    list(GET SIZES 1 N)
    list(GET SIZES 2 K)

    if(${BACKEND} STREQUAL "mlir")
      compile_mlir(${MATMUL} ${M} ${N} ${K} OFF OFF) # nodai == OFF, mlircuda == OFF
      list(APPEND SRC ${CMAKE_BINARY_DIR}/mlir-objs/${MATMUL}.o)
    elseif(${BACKEND} STREQUAL "nodai")
      compile_mlir(${MATMUL} ${M} ${N} ${K} ON OFF) # nodai == ON, mlircuda == OFF
      list(APPEND SRC ${CMAKE_BINARY_DIR}/mlir-objs/${MATMUL}.o)
    elseif(${BACKEND} STREQUAL "mlircuda")
      compile_mlir(${MATMUL} ${M} ${N} ${K} OFF ON) # nodai == OFF, mlircuda == ON
      list(APPEND SRC ${CMAKE_BINARY_DIR}/mlir-objs/${MATMUL}.o)
    elseif(${BACKEND} STREQUAL "ireellvmsandbox")
      list(GET SANDBOX_TILE_SIZES ${SANDBOX_TILE_SIZES_FILE_LINE_COUNTER} FIRST_TILE_SIZE)
      MATH(EXPR SANDBOX_TILE_SIZES_FILE_LINE_COUNTER "${SANDBOX_TILE_SIZES_FILE_LINE_COUNTER}+1")
      list(GET SANDBOX_TILE_SIZES ${SANDBOX_TILE_SIZES_FILE_LINE_COUNTER} SECOND_TILE_SIZE)
      MATH(EXPR SANDBOX_TILE_SIZES_FILE_LINE_COUNTER "${SANDBOX_TILE_SIZES_FILE_LINE_COUNTER}+1")
      list(GET SANDBOX_TILE_SIZES ${SANDBOX_TILE_SIZES_FILE_LINE_COUNTER} THIRD_TILE_SIZE)
      MATH(EXPR SANDBOX_TILE_SIZES_FILE_LINE_COUNTER "${SANDBOX_TILE_SIZES_FILE_LINE_COUNTER}+1")
    
      compile_llvm_sandbox_mlir(${MATMUL} ${M} ${N} ${K})
      list(APPEND SRC ${CMAKE_BINARY_DIR}/mlir-objs/${MATMUL}.o)
    endif()
    add_executable(${MATMUL} ${SRC})
    target_compile_definitions(${MATMUL} PRIVATE MDIM=${M})
    target_compile_definitions(${MATMUL} PRIVATE NDIM=${N})
    target_compile_definitions(${MATMUL} PRIVATE KDIM=${K})
    target_compile_definitions(${MATMUL} PRIVATE NUM_REPS=${NUM_REPS})
    target_compile_definitions(${MATMUL} PRIVATE FILE_NAME=${MATMUL}_perf.out)
    if(${USE_COLUMN_MAJOR} STREQUAL "ON")
      target_compile_definitions(${MATMUL} PRIVATE COLUMN_MAJOR)
    endif()
    if (ENABLE_CHECK)
        target_compile_definitions(${MATMUL} PRIVATE ENABLE_CHECK)
    endif()
    if(${BACKEND} STREQUAL "mkl")
      target_compile_definitions(${MATMUL} PRIVATE MKL)
      target_include_directories(${MATMUL} PRIVATE ${MKL_DIR}/include)
      target_link_directories(${MATMUL} PRIVATE ${MKL_DIR}/lib/intel64)
      target_link_libraries(${MATMUL} PRIVATE mkl_intel_ilp64 mkl_gnu_thread mkl_core gomp)
    elseif(${BACKEND} STREQUAL "accelerate")
      set(BLA_VENDOR Apple)
      find_package(BLAS)
      target_include_directories(${MATMUL} PRIVATE /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Accelerate.framework/Versions/Current/Frameworks/vecLib.framework/Headers)
      target_compile_definitions(${MATMUL} PRIVATE ACCELERATE)
      target_link_libraries(${MATMUL} PRIVATE ${BLAS_LIBRARIES})
    elseif(${BACKEND} STREQUAL "blis")
      target_compile_definitions(${MATMUL} PRIVATE BLIS)
      target_include_directories(${MATMUL} PRIVATE ${BLIS_DIR}/include/blis)
      target_link_directories(${MATMUL} PRIVATE ${BLIS_DIR}/lib)
      target_link_libraries(${MATMUL} PRIVATE blis)
    elseif(${BACKEND} STREQUAL "cublas")
      target_compile_definitions(${MATMUL} PRIVATE CUBLAS)
      target_include_directories(${MATMUL} PRIVATE ${CUDA_INCLUDE_DIRS})
      target_link_libraries(${MATMUL} PRIVATE ${CUDA_CUBLAS_LIBRARIES} ${CUDA_LIBRARIES})
    elseif(${BACKEND} STREQUAL "openblas")
      target_compile_definitions(${MATMUL} PRIVATE OPENBLAS)
      target_link_libraries(${MATMUL} PRIVATE openblas)
    elseif(${BACKEND} STREQUAL "blasfeo")
      target_compile_definitions(${MATMUL} PRIVATE BLASFEO)
      target_include_directories(${MATMUL} PRIVATE ${BLASFEO_DIR}/include)
      target_link_libraries(${MATMUL} PRIVATE ${BLASFEO_DIR}/lib/libblasfeo.a)
    elseif(${BACKEND} STREQUAL "halide")
      target_compile_definitions(${MATMUL} PRIVATE HALIDE)
      target_link_libraries(${MATMUL} PRIVATE halide_blas)
    elseif(${BACKEND} STREQUAL "ruy")
      target_compile_definitions(${MATMUL} PRIVATE RUY)
      target_include_directories(${MATMUL} PRIVATE ${RUY_SOURCE})
      target_link_libraries(${MATMUL} PRIVATE ruy)
    elseif(${BACKEND} STREQUAL "tvm")
      target_compile_definitions(${MATMUL} PRIVATE TVM)
      if(${USE_TVM_TUNED} STREQUAL "ON")
        target_compile_definitions(${MATMUL} PRIVATE USE_TVM_TUNED)
        set(TVM_LIB ${TVM_LIB_DIR}/matmul_${M}x${N}x${K}.so)
        target_compile_definitions(${MATMUL} PRIVATE TVM_LIB=${TVM_LIB})
      endif()
      if(${TVM_ENABLE_CUDA} STREQUAL "ON")
        target_compile_definitions(${MATMUL} PRIVATE TVM_ENABLE_CUDA)
      endif()
      if(${TVM_ENABLE_ROCM} STREQUAL "ON")
        target_compile_definitions(${MATMUL} PRIVATE TVM_ENABLE_ROCM)
      endif()
      if(${TVM_ENABLE_METAL} STREQUAL "ON")
        target_compile_definitions(${MATMUL} PRIVATE TVM_ENABLE_METAL)
      endif()
      set(TVM_INSTALL_DIR  ${CMAKE_BINARY_DIR}/../tvm-install)
      set(TVM_SOURCE_DIR ${CMAKE_SOURCE_DIR}/../external/tvm)
      target_link_directories(${MATMUL} PRIVATE ${TVM_INSTALL_DIR}/lib)
      target_link_libraries(${MATMUL} PRIVATE tvm)
      target_include_directories(${MATMUL} PRIVATE
        ${TVM_SOURCE_DIR}/include
        ${TVM_SOURCE_DIR}/3rdparty/dmlc-core/include
        ${TVM_SOURCE_DIR}/3rdparty/dlpack/include
        ${TVM_INSTALL_DIR}/include
      )
    elseif(${BACKEND} STREQUAL "mlir")
      target_compile_definitions(${MATMUL} PRIVATE MLIR)
    elseif(${BACKEND} STREQUAL "mlircuda")
      target_compile_definitions(${MATMUL} PRIVATE MLIR_CUDA)
      target_include_directories(${MATMUL} PRIVATE ${CUDA_INCLUDE_DIRS})
      target_link_libraries(${MATMUL} PRIVATE ${CUDA_LIBRARIES})
      if (DEFINED PREBUILT_LLVM_PATH AND (NOT PREBUILT_LLVM_PATH STREQUAL ""))
        target_link_libraries(${MATMUL} PRIVATE ${PREBUILT_LLVM_PATH}/lib/libmlir_cuda_runtime.so)
        target_link_libraries(${MATMUL} PRIVATE ${PREBUILT_LLVM_PATH}/lib/libmlir_runner_utils.so)
      else()
        target_link_libraries(${MATMUL} PRIVATE ${MLIR_BUILD}/lib/libmlir_cuda_runtime.so)
        target_link_libraries(${MATMUL} PRIVATE ${MLIR_BUILD}/lib/libmlir_runner_utils.so)
      endif()
    elseif(${BACKEND} STREQUAL "ireellvmsandbox")
      target_link_libraries(${MATMUL} PRIVATE ${MLIR_BUILD}/lib/libmlir_cuda_runtime.so)
      target_link_libraries(${MATMUL} PRIVATE ${MLIR_BUILD}/lib/libmlir_runner_utils.so)
      target_compile_definitions(${MATMUL} PRIVATE IREE_LLVM_SANDBOX)
    elseif(${BACKEND} STREQUAL "nodai")
      target_compile_definitions(${MATMUL} PRIVATE MLIR)
    elseif(${BACKEND} STREQUAL "naive")
      target_compile_definitions(${MATMUL} PRIVATE NAIVE)
      target_compile_options(${MATMUL} PRIVATE -O3)
    endif()
    target_link_libraries(${MATMUL} PRIVATE m)
    list(APPEND ALL_TARGETS ${MATMUL})
  endforeach()
endforeach()

add_custom_target(run_all_tests
    ${CMAKE_SOURCE_DIR}/../mmperf.py
    ${CMAKE_BINARY_DIR}
    ${CMAKE_SOURCE_DIR}/../results/${TARGET_CPU}
    DEPENDS ${ALL_TARGETS}
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}/..)
