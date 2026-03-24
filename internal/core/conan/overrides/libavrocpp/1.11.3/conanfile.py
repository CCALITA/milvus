from conan import ConanFile
from conan.tools.files import apply_conandata_patches, export_conandata_patches, get, copy, rm, replace_in_file
from conan.tools.build import check_min_cppstd
from conan.tools.cmake import CMake, CMakeDeps, CMakeToolchain, cmake_layout
import os

required_conan_version = ">=1.54.0"


class LibavrocppConan(ConanFile):
    name = "libavrocpp"
    description = "Avro is a data serialization system."
    license = "Apache-2.0"
    url = "https://github.com/conan-io/conan-center-index"
    homepage = "https://avro.apache.org/"
    topics = ("serialization", "deserialization", "avro")
    package_type = "library"
    settings = "os", "arch", "compiler", "build_type"
    options = {
        "shared": [True, False],
        "fPIC": [True, False],
    }
    default_options = {
        "shared": False,
        "fPIC": True,
    }
    short_paths = True

    @property
    def _min_cppstd(self):
        return 11

    def export_sources(self):
        export_conandata_patches(self)

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def configure(self):
        if self.options.shared:
            self.options.rm_safe("fPIC")

    def layout(self):
        cmake_layout(self, src_folder="src")

    def requirements(self):
        self.requires("boost/1.81.0", transitive_headers=True)
        self.requires("snappy/1.1.9")

    def validate(self):
        if self.settings.compiler.get_safe("cppstd"):
            check_min_cppstd(self, self._min_cppstd)

    def source(self):
        get(self, **self.conan_data["sources"][self.version], strip_root=True)

    def generate(self):
        tc = CMakeToolchain(self)
        tc.generate()

        deps = CMakeDeps(self)
        deps.generate()

    def _patch_sources(self):
        apply_conandata_patches(self)
        cmakelists = os.path.join(self.source_folder, "lang", "c++", "CMakeLists.txt")
        replace_in_file(self, cmakelists, "SNAPPY_FOUND", "Snappy_FOUND")
        replace_in_file(self, cmakelists, "${SNAPPY_LIBRARIES}", "Snappy::snappy")
        replace_in_file(
            self,
            cmakelists,
            "target_include_directories(avrocpp_s PRIVATE ${SNAPPY_INCLUDE_DIR})",
            "target_link_libraries(avrocpp_s PRIVATE Snappy::snappy)",
        )
        target = "avrocpp" if self.options.shared else "avrocpp_s"
        replace_in_file(self, cmakelists, "install (TARGETS avrocpp avrocpp_s", f"install (TARGETS {target}")

        # Milvus only consumes the libavrocpp library. Under the Linux clang+libc++ path,
        # the upstream avrogencpp/test-codegen executable path trips a Boost/libc++ ABI
        # mismatch long before Milvus itself is built. Skip those non-library targets while
        # still building the public-source library package.
        replace_in_file(self, cmakelists, "add_executable (precompile test/precompile.cc)", "if(FALSE)\nadd_executable (precompile test/precompile.cc)")
        replace_in_file(self, cmakelists, "install (TARGETS avrogencpp RUNTIME DESTINATION bin)", "install (TARGETS avrogencpp RUNTIME DESTINATION bin)\nendif()")

    def build(self):
        self._patch_sources()
        cmake = CMake(self)
        cmake.configure(build_script_folder=os.path.join(self.source_folder, "lang", "c++"))
        cmake.build()

    def package(self):
        copy(self, pattern="LICENSE", dst=os.path.join(self.package_folder, "licenses"), src=self.source_folder)
        copy(self, pattern="NOTICE*", dst=os.path.join(self.package_folder, "licenses"), src=self.source_folder)
        cmake = CMake(self)
        cmake.install()

        lib_dst = os.path.join(self.package_folder, "lib")
        copy(self, pattern="libavrocpp*.a", dst=lib_dst, src=self.build_folder, keep_path=False)
        copy(self, pattern="libavrocpp*.so*", dst=lib_dst, src=self.build_folder, keep_path=False)
        copy(self, pattern="avrocpp*.lib", dst=lib_dst, src=self.build_folder, keep_path=False)
        copy(self, pattern="avrocpp*.dll", dst=os.path.join(self.package_folder, "bin"), src=self.build_folder, keep_path=False)

        if self.settings.os == "Windows":
            for dll_pattern_to_remove in ["concrt*.dll", "msvcp*.dll", "vcruntime*.dll"]:
                rm(self, dll_pattern_to_remove, os.path.join(self.package_folder, "bin"))

    def package_info(self):
        self.cpp_info.libs = ["avrocpp"] if self.options.shared else ["avrocpp_s"]
        if self.options.shared:
            self.cpp_info.defines.append("AVRO_DYN_LINK")
        if self.settings.os in ["Linux", "FreeBSD"]:
            self.cpp_info.system_libs.append("m")
        self.cpp_info.requires = [
            "boost::headers", "boost::filesystem", "boost::iostreams", "boost::program_options",
            "boost::regex", "boost::system", "snappy::snappy",
        ]
