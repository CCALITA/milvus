# Copyright (C) 2019-2020 Zilliz. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied. See the License for the specific language governing permissions and limitations under the License

find_package(Protobuf REQUIRED)

add_source_at_current_directory_recursively()
# Some branches/vendors may not ship generated protobuf sources in-tree.
# Make this target a no-op object library in that case to keep the build graph valid.
if(SOURCE_FILES)
  add_library(milvus_pb OBJECT ${SOURCE_FILES})
else()
  # CMake does not allow OBJECT libraries with zero sources.
  # Create a tiny dummy translation unit so the target exists.
  file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/milvus_pb_dummy.cc
"// Auto-generated dummy file (no protobuf sources in this checkout)\n\nnamespace milvus { int milvus_pb_dummy() { return 0; } }\n")
  add_library(milvus_pb OBJECT ${CMAKE_CURRENT_BINARY_DIR}/milvus_pb_dummy.cc)
endif()
