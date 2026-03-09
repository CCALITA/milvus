from conans import ConanFile, tools


class MilvusConan(ConanFile):
    keep_imports = True
    settings = "os", "compiler", "build_type", "arch"

    # Force cmake tool as build-require.
    build_requires = (
        "cmake/3.30.5",
    )

    requires = (
        "rocksdb/6.29.5",
        "boost/1.85.0",
        "onetbb/2021.9.0",
        "nlohmann_json/3.11.3",
        "rapidjson/1.1.0",
        "zstd/1.5.5",
        "lz4/1.9.4",
        "snappy/1.1.9",
        "arrow/17.0.0",
        "openssl/3.1.2",
        "googleapis/cci.20221108",
        "google-cloud-cpp/2.5.0",
        "gtest/1.13.0",
        "protobuf/3.21.12",
        "yaml-cpp/0.7.0",
        "zlib/1.2.13",
        "libcurl/7.86.0",
        "glog/0.6.0",
        "fmt/9.1.0",
        "gflags/2.2.2",
        "double-conversion/3.2.1",
        "libsodium/cci.20220430",
        "xz_utils/5.4.0",
        "re2/20230301",
        "abseil/20230125.3",

        # needed by internal/core/thirdparty/milvus-common
        "opentelemetry-cpp/1.9.1",
        "folly/2024.08.12.00",
        "prometheus-cpp/1.1.0",
        "libavrocpp/1.11.3",
        "aws-sdk-cpp/1.11.352",

        "roaring/3.0.0",
        "xxhash/0.8.2",
        "simde/0.8.2",
        "geos/3.12.0",
        "unordered_dense/4.4.0",
        "marisa/0.2.6",
        "librdkafka/2.6.0",
    )

    generators = ("cmake", "cmake_find_package")

    default_options = {
        "openssl:shared": True,
        "double-conversion:shared": True,

        "rocksdb:shared": True,
        "rocksdb:with_zstd": True,

        "arrow:filesystem_layer": True,
        "arrow:parquet": True,
        "arrow:compute": True,
        "arrow:with_re2": True,
        "arrow:with_zstd": True,
        "arrow:with_boost": True,
        "arrow:with_thrift": True,
        "arrow:with_openssl": True,
        "arrow:shared": False,
        "arrow:with_s3": False,

        "gtest:build_gmock": True,

        # boost: keep required components; disable heavy/unused ones
        "boost:without_locale": False,
        "boost:without_python": True,
        "boost:without_mpi": True,
        "boost:without_test": True,
        "boost:without_stacktrace": True,
        "boost:without_graph": True,
        "boost:without_log": True,

        "glog:with_gflags": True,
        "glog:with_unwind": False,
        "glog:shared": True,

        "fmt:header_only": False,

        "xxhash:shared": True,
        "xxhash:utility": False,

        "geos:shared": True,
        "geos:utils": False,

        "onetbb:tbbmalloc": False,
        "onetbb:tbbproxy": False,

        "folly:shared": True,
        "google-cloud-cpp:shared": True,

        "librdkafka:shared": True,

        "aws-sdk-cpp:shared": True,
        "aws-sdk-cpp:s3": True,
        "aws-sdk-cpp:sts": True,
        "aws-sdk-cpp:iam": True,
        "aws-sdk-cpp:identity-management": True,
        "aws-sdk-cpp:transfer": False,
        "aws-sdk-cpp:text-to-speech": False,

        "prometheus-cpp:with_pull": False,
        "prometheus-cpp:with_push": True,
        "prometheus-cpp:shared": True,

        "opentelemetry-cpp:with_abseil": True,
        "opentelemetry-cpp:with_otlp": True,
        "opentelemetry-cpp:with_otlp_grpc": True,
        "opentelemetry-cpp:with_otlp_http": True,
        "opentelemetry-cpp:with_jaeger": True,
        "opentelemetry-cpp:with_prometheus": False,
        "opentelemetry-cpp:with_stl": True,
    }

    def configure(self):
        if self.settings.os == "Macos":
            self.options["abseil"].shared = True
            self.options["arrow"].with_jemalloc = False
            self.options["arrow"].with_s3 = False
            self.options["libcurl"].with_ssl = "openssl"

    def requirements(self):
        # Align thrift to Arrow
        self.requires("thrift/0.20.0")

        enable_azure_fs = str(tools.get_env("ENABLE_AZURE_FS", "ON")).upper()
        if enable_azure_fs not in ("0", "OFF", "FALSE", "NO"):
            self.requires("azure-sdk-for-cpp/1.11.3")

    def imports(self):
        self.copy("*.dylib", "../lib", "lib")
        self.copy("*.dll", "../lib", "lib")
        self.copy("*.so*", "../lib", "lib")
        self.copy("*", "../bin", "bin")
        self.copy("*.proto", "../include", "include")
