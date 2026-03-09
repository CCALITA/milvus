from conan import ConanFile
from conan.tools.files import copy, load, save
import os


class GnuConfigConan(ConanFile):
    name = "gnu-config"
    version = "cci.20210814"
    description = "The GNU config.guess and config.sub scripts"
    homepage = "https://savannah.gnu.org/projects/config/"
    license = "GPL-3.0-or-later", "autoconf-special-exception"
    package_type = "build-scripts"

    # Fully offline override: ship the scripts as exported sources.
    exports_sources = "config.guess", "config.sub"

    def package_id(self):
        # Same package for all settings (build helper scripts)
        self.info.clear()

    def _extract_license(self):
        txt_lines = load(self, os.path.join(self.export_sources_folder, "config.guess")).splitlines()
        start_index = None
        end_index = None
        for line_i, line in enumerate(txt_lines):
            if start_index is None and "This file is free" in line:
                start_index = line_i
            if end_index is None and "Please send patches" in line:
                end_index = line_i
        if not all((start_index, end_index)):
            # Fallback: store a short notice instead of failing the build.
            return "GNU config.guess/config.sub (license text unavailable to extractor)"
        return "\n".join(txt_lines[start_index:end_index])

    def package(self):
        save(self, os.path.join(self.package_folder, "licenses", "COPYING"), self._extract_license())
        bin_path = os.path.join(self.package_folder, "bin")
        copy(self, "config.guess", src=self.export_sources_folder, dst=bin_path)
        copy(self, "config.sub", src=self.export_sources_folder, dst=bin_path)

    def package_info(self):
        self.cpp_info.includedirs = []
        self.cpp_info.libdirs = []

        bin_path = os.path.join(self.package_folder, "bin")
        self.conf_info.define("user.gnu-config:config_guess", os.path.join(bin_path, "config.guess"))
        self.conf_info.define("user.gnu-config:config_sub", os.path.join(bin_path, "config.sub"))

        # Conan 1 compatibility
        self.user_info.CONFIG_GUESS = os.path.join(bin_path, "config.guess")
        self.user_info.CONFIG_SUB = os.path.join(bin_path, "config.sub")
        self.env_info.PATH.append(bin_path)
