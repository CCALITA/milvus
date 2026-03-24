# CMake find module for xxHash used by knowhere (expects xxHash::xxhash)
#
# We rely on Conan-provided variables from conanbuildinfo.cmake:
#   CONAN_INCLUDE_DIRS_XXHASH, CONAN_LIB_DIRS_XXHASH, CONAN_LIBS_XXHASH

include(FindPackageHandleStandardArgs)

# If Conan populated these, use them.
set(_xxhash_hints_inc "${CONAN_INCLUDE_DIRS_XXHASH}")
set(_xxhash_hints_lib "${CONAN_LIB_DIRS_XXHASH}")

find_path(xxHash_INCLUDE_DIRS
  NAMES xxhash.h
  HINTS ${_xxhash_hints_inc}
)

find_library(xxHash_LIBRARY
  NAMES xxhash
  HINTS ${_xxhash_hints_lib}
)

set(xxHash_LIBRARIES "${xxHash_LIBRARY}")

find_package_handle_standard_args(xxHash
  REQUIRED_VARS xxHash_INCLUDE_DIRS xxHash_LIBRARY
)

if(xxHash_FOUND AND NOT TARGET xxHash::xxhash)
  add_library(xxHash::xxhash UNKNOWN IMPORTED)
  set_target_properties(xxHash::xxhash PROPERTIES
    IMPORTED_LOCATION "${xxHash_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${xxHash_INCLUDE_DIRS}"
  )
endif()
