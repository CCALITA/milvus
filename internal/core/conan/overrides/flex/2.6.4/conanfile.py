import os
import shutil

from conan import ConanFile
from conan.errors import ConanInvalidConfiguration
from conan.tools.apple import fix_apple_shared_install_name
from conan.tools.build import cross_building
from conan.tools.files import get, rmdir, copy, rm, export_conandata_patches, apply_conandata_patches, mkdir
from conan.tools.env import Environment
from conan.tools.gnu import AutotoolsToolchain, Autotools

required_conan_version = ">=1.53.0"


class FlexConan(ConanFile):
    name = "flex"
    url = "https://github.com/conan-io/conan-center-index"
    homepage = "https://github.com/westes/flex"
    description = "Flex, the fast lexical analyzer generator"
    topics = ("lex", "lexer", "lexical analyzer generator")
    license = "BSD-2-Clause"

    settings = "os", "arch", "compiler", "build_type"
    options = {
        "shared": [True, False],
        "fPIC": [True, False],
    }
    default_options = {
        "shared": False,
        "fPIC": True,
    }

    def source(self):
        get(self, **self.conan_data["sources"][self.version], strip_root=True)

    def export_sources(self):
        export_conandata_patches(self)

    def requirements(self):
        self.requires("m4/1.4.19")

    def build_requirements(self):
        self.tool_requires("m4/1.4.19")
        # Flex's generated build rules can spuriously regenerate autotools files on the
        # Linux Nix clang+libc++ proof path, so keep automake available in the build env.
        self.tool_requires("automake/1.16.5")
        if hasattr(self, "settings_build") and cross_building(self):
            self.tool_requires(f"{self.name}/{self.version}")

    def validate(self):
        if self.settings.os == "Windows":
            raise ConanInvalidConfiguration("Flex package is not compatible with Windows. Consider using winflexbison instead.")

    def configure(self):
        if self.options.shared:
            self.options.rm_safe("fPIC")

        self.settings.rm_safe("compiler.libcxx")
        self.settings.rm_safe("compiler.cppstd")

    def generate(self):
        at = AutotoolsToolchain(self)
        at.configure_args.extend([
            "--disable-nls",
            "--disable-bootstrap",
            "HELP2MAN=/bin/true",
            "MAKEINFO=/bin/true",
            "M4=m4",
            "ac_cv_func_malloc_0_nonnull=yes",
            "ac_cv_func_realloc_0_nonnull=yes",
            "ac_cv_func_reallocarray=no",
        ])
        at.generate()

    def build(self):
        apply_conandata_patches(self)
        # On the Linux Nix clang+libc++ proof host, Conan 1 can unpack Flex's generated
        # configure script without its executable bit. Keep using the same public release
        # tarball, but restore the mode before autotools.configure() executes it.
        for helper in (
            "configure",
            os.path.join("build-aux", "missing"),
            os.path.join("build-aux", "ylwrap"),
            "mkskel.sh",
        ):
            helper_path = os.path.join(self.source_folder, helper)
            if os.path.isfile(helper_path):
                os.chmod(helper_path, 0o755)

        # Some proof-host runs also copy parse.y a few milliseconds newer than the already
        # generated parse.c/parse.h, which needlessly re-enters the maintainer-only bison
        # path. Keep the packaged generated parser newer than its source so the public
        # release tarball builds without introducing a flex<->bison recipe cycle.
        parser_outputs = (os.path.join("src", "parse.c"), os.path.join("src", "parse.h"))
        newest_mtime = None
        parse_y = os.path.join(self.source_folder, "src", "parse.y")
        if os.path.isfile(parse_y):
            newest_mtime = os.stat(parse_y).st_mtime + 1
        for relpath in parser_outputs:
            generated = os.path.join(self.source_folder, relpath)
            if os.path.isfile(generated):
                if newest_mtime is None:
                    newest_mtime = os.stat(generated).st_mtime + 1
                os.utime(generated, (newest_mtime, newest_mtime))

        # Some proof-host runs also spuriously trigger Flex's maintainer regeneration path,
        # which hardcodes aclocal-1.15/automake-1.15 names. Provide tiny wrappers to the
        # available automake toolchain instead of mutating upstream sources.
        shim_dir = os.path.join(self.build_folder, "openclaw-flex-tool-shims")
        mkdir(self, shim_dir)
        aclocal = shutil.which("aclocal") or shutil.which("aclocal-1.16")
        automake = shutil.which("automake") or shutil.which("automake-1.16")
        for target, alias in ((aclocal, "aclocal-1.15"), (automake, "automake-1.15")):
            if target and os.path.isfile(target):
                shim = os.path.join(shim_dir, alias)
                if os.path.lexists(shim):
                    os.remove(shim)
                with open(shim, "w", encoding="utf-8") as handle:
                    handle.write("#!/usr/bin/env bash\n")
                    handle.write("exec \"{}\" \"$@\"\n".format(target))
                os.chmod(shim, 0o755)
        env = Environment()
        env.prepend_path("PATH", shim_dir)
        build_env = env.vars(self, scope="build")
        autotools = Autotools(self)
        with build_env.apply():
            autotools.configure()
            autotools.make()

    def package(self):
        copy(self, "COPYING", src=self.source_folder, dst=os.path.join(self.package_folder, "licenses"))
        autotools = Autotools(self)
        autotools.install()
        rmdir(self, os.path.join(self.package_folder, "share"))
        rm(self, "*.la", os.path.join(self.package_folder, "lib"))
        fix_apple_shared_install_name(self)

    def package_info(self):
        self.cpp_info.libs = ["fl"]
        self.cpp_info.system_libs = ["m"]
        self.cpp_info.set_property("cmake_find_mode", "none")

        bindir = os.path.join(self.package_folder, "bin")
        self.output.info("Appending PATH environment variable: {}".format(bindir))
        self.env_info.PATH.append(bindir)

        lex_path = os.path.join(bindir, "flex").replace("\\", "/")
        self.output.info("Setting LEX environment variable: {}".format(lex_path))
        self.env_info.LEX = lex_path
