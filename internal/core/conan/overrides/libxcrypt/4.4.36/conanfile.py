from conan import ConanFile
from conan.errors import ConanInvalidConfiguration
from conan.tools.apple import fix_apple_shared_install_name
from conan.tools.env import VirtualBuildEnv
from conan.tools.files import copy, get, replace_in_file, rm, rmdir
from conan.tools.gnu import Autotools, AutotoolsToolchain
from conan.tools.layout import basic_layout
from conan.tools.microsoft import is_msvc, unix_path
import os

required_conan_version = ">=1.53.0"


class LibxcryptConan(ConanFile):
    name = "libxcrypt"
    url = "https://github.com/conan-io/conan-center-index"
    homepage = "https://github.com/besser82/libxcrypt"
    description = "Extended crypt library for descrypt, md5crypt, bcrypt, and others"
    topics = ("hash", "password", "one-way", "bcrypt", "md5", "sha256", "sha512")
    license = ("LGPL-2.1-or-later", )
    settings = "os", "arch", "compiler", "build_type"
    package_type = "library"
    options = {
        "shared": [True, False],
        "fPIC": [True, False],
    }
    default_options = {
        "shared": False,
        "fPIC": True,
    }

    @property
    def _settings_build(self):
        return getattr(self, "settings_build", self.settings)

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def configure(self):
        if self.options.shared:
            self.options.rm_safe("fPIC")
        self.settings.rm_safe("compiler.libcxx")
        self.settings.rm_safe("compiler.cppstd")

    def layout(self):
        basic_layout(self, src_folder="src")

    def validate(self):
        if is_msvc(self):
            raise ConanInvalidConfiguration(f"{self.ref} does not support Visual Studio")

    def build_requirements(self):
        self.tool_requires("libtool/2.4.7")
        if self._settings_build.os == "Windows":
            self.win_bash = True
            if not self.conf.get("tools.microsoft.bash:path", check_type=str):
                self.tool_requires("msys2/cci.latest")

    def source(self):
        get(self, **self.conan_data["sources"][self.version],
            destination=self.source_folder, strip_root=True)

    def generate(self):
        env = VirtualBuildEnv(self)
        env.generate()
        tc = AutotoolsToolchain(self)
        tc.configure_args.append("--disable-werror")
        tc.generate()

    def _patch_sources(self):
        replace_in_file(self, os.path.join(self.source_folder, "Makefile.am"),
                              "\nlibcrypt_la_LDFLAGS = ", "\nlibcrypt_la_LDFLAGS = -no-undefined ")

    def build(self):
        self._patch_sources()
        libtool_pkg = self.dependencies.build["libtool"].package_folder
        libtool_res_dir = os.path.join(libtool_pkg, "res")
        libtool_datadir = os.path.join(libtool_res_dir, "libtool")
        aclocal_dir = os.path.join(libtool_res_dir, "aclocal")
        libtool_shim_dir = os.path.join(self.build_folder, ".libtool-share")
        os.makedirs(libtool_shim_dir, exist_ok=True)
        for name, target in {
            "build-aux": os.path.join(libtool_datadir, "build-aux"),
            "libltdl": os.path.join(libtool_datadir, "libltdl"),
            "m4": aclocal_dir,
        }.items():
            link_path = os.path.join(libtool_shim_dir, name)
            if os.path.lexists(link_path):
                os.unlink(link_path)
            os.symlink(target, link_path)
        os.environ["_lt_pkgdatadir"] = libtool_shim_dir
        os.environ["ACLOCAL_PATH"] = os.pathsep.join(filter(None, [aclocal_dir, os.environ.get("ACLOCAL_PATH", "")]))
        os.environ["AUTOMAKE_CONAN_INCLUDES"] = os.pathsep.join(filter(None, [aclocal_dir, os.environ.get("AUTOMAKE_CONAN_INCLUDES", "")]))
        autotools = Autotools(self)
        autotools.autoreconf()
        autotools.configure()
        if self.settings.os == "Windows":
            replace_in_file(self, os.path.join(self.build_folder, "libtool"), "-DPIC", "")
        autotools.make()

    def package(self):
        copy(self, "COPYING.LIB", src=self.source_folder, dst=os.path.join(self.package_folder, "licenses"))
        autotools = Autotools(self)
        # TODO: replace by autotools.install() once https://github.com/conan-io/conan/issues/12153 fixed
        autotools.install(args=[f"DESTDIR={unix_path(self, self.package_folder)}"])
        rm(self, "*.la", os.path.join(self.package_folder, "lib"))
        rmdir(self, os.path.join(self.package_folder, "lib", "pkgconfig"))
        # The upstream recipe removes pkgconfig output but leaves a top-level
        # libcrypt.pc -> libxcrypt.pc symlink behind. Under Conan 1.64 this is
        # then treated as a broken symlink and aborts packaging on Linux.
        rm(self, "libcrypt.pc", self.package_folder)
        rm(self, "libxcrypt.pc", self.package_folder)
        rmdir(self, os.path.join(self.package_folder, "share"))
        fix_apple_shared_install_name(self)

    def package_info(self):
        self.cpp_info.set_property("pkg_config_name", "libxcrypt")
        self.cpp_info.libs = ["crypt"]
