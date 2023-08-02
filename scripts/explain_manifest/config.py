
from copy import deepcopy

from globmatch import glob_match

from main import FileInfo
from expect import ExpectSuite
from suites import common_suites, ee_suites, libc_libcpp_suites, arm64_suites, docker_suites


def transform(f: FileInfo):
    # XXX: libxslt uses libtool and it injects some extra rpaths
    # we only care about the kong library rpath so removing it here
    # until we find a way to remove the extra rpaths from it
    # It should have no side effect as the extra rpaths are long random
    # paths created by bazel.

    if glob_match(f.path, ["**/kong/lib/libxslt.so*", "**/kong/lib/libexslt.so*", "**/kong/lib/libjq.so*"]):
        expected_rpath = "/usr/local/kong/lib"
        if f.rpath and expected_rpath in f.rpath:
            f.rpath = expected_rpath
        elif f.runpath and expected_rpath in f.runpath:
            f.runpath = expected_rpath
        # otherwise remain unmodified

    if f.path.endswith("/modules/ngx_wasm_module.so"):
        expected_rpath = "/usr/local/openresty/luajit/lib:/usr/local/kong/lib"
        if f.rpath and expected_rpath in f.rpath:
            f.rpath = expected_rpath
        elif f.runpath and expected_rpath in f.runpath:
            f.runpath = expected_rpath
        # otherwise remain unmodified

    # XXX: boringssl also hardcodes the rpath during build; normally library
    # loads libssl.so also loads libcrypto.so so we _should_ be fine.
    # we are also replacing boringssl with openssl 3.0 for FIPS for not fixing this for now
    if glob_match(f.path, ["**/kong/lib/libssl.so.1.1"]):
        if f.runpath and "boringssl_fips/build/crypto" in f.runpath:
            f.runpath = "<removed in manifest>"
        elif f.rpath and "boringssl_fips/build/crypto" in f.rpath:
            f.rpath = "<removed in manifest>"


# libc:
# - https://repology.org/project/glibc/versions
# GLIBCXX and CXXABI based on gcc version:
# - https://gcc.gnu.org/onlinedocs/libstdc++/manual/abi.html
# - https://repology.org/project/gcc/versions
# TODO: libstdc++ verions
targets = {
    "alpine-amd64": ExpectSuite(
        name="Alpine Linux (amd64)",
        manifest="fixtures/alpine-amd64.txt",
        use_rpath=True,
        tests={
            common_suites: {},
            libc_libcpp_suites: {
                # alpine 3.16: gcc 11.2.1
                "libcxx_max_version": "3.4.29",
                "cxxabi_max_version": "1.3.13",
            },
            ee_suites: {},
        }
    ),
    "amazonlinux-2-amd64": ExpectSuite(
        name="Amazon Linux 2 (amd64)",
        manifest="fixtures/amazonlinux-2-amd64.txt",
        use_rpath=True,
        tests={
            common_suites: {},
            libc_libcpp_suites: {
                "libc_max_version": "2.26",
                # gcc 7.3.1
                "libcxx_max_version": "3.4.24",
                "cxxabi_max_version": "1.3.11",
            },
            ee_suites: {},
        },
    ),
    "amazonlinux-2023-amd64": ExpectSuite(
        name="Amazon Linux 2023 (amd64)",
        manifest="fixtures/amazonlinux-2023-amd64.txt",
        tests={
            common_suites: {
                "libxcrypt_no_obsolete_api": True,
            },
            libc_libcpp_suites: {
                "libc_max_version": "2.34",
                # gcc 11.2.1
                "libcxx_max_version": "3.4.29",
                "cxxabi_max_version": "1.3.13",
            },
            ee_suites: {},
        },
    ),
    "el7-amd64": ExpectSuite(
        name="Redhat 7 (amd64)",
        manifest="fixtures/el7-amd64.txt",
        use_rpath=True,
        tests={
            common_suites: {},
            libc_libcpp_suites: {
                "libc_max_version": "2.17",
                # gcc 4.8.5
                "libcxx_max_version": "3.4.19",
                "cxxabi_max_version": "1.3.7",
            },
            ee_suites: {},
        }
    ),
    "el8-amd64": ExpectSuite(
        name="Redhat 8 (amd64)",
        manifest="fixtures/el8-amd64.txt",
        use_rpath=True,
        tests={
            common_suites: {},
            libc_libcpp_suites: {
                "libc_max_version": "2.28",
                # gcc 8.5.0
                "libcxx_max_version": "3.4.25",
                "cxxabi_max_version": "1.3.11",
            },
            ee_suites: {},
        },
    ),
    "el9-amd64": ExpectSuite(
        name="Redhat 8 (amd64)",
        manifest="fixtures/el9-amd64.txt",
        use_rpath=True,
        tests={
            common_suites: {
                "libxcrypt_no_obsolete_api": True,
            },
            libc_libcpp_suites: {
                "libc_max_version": "2.34",
                # gcc 11.3.1
                "libcxx_max_version": "3.4.29",
                "cxxabi_max_version": "1.3.13",
            },
            ee_suites: {},
        }
    ),
    "ubuntu-20.04-amd64": ExpectSuite(
        name="Ubuntu 20.04 (amd64)",
        manifest="fixtures/ubuntu-20.04-amd64.txt",
        tests={
            common_suites: {},
            libc_libcpp_suites: {
                "libc_max_version": "2.30",
                # gcc 9.3.0
                "libcxx_max_version": "3.4.28",
                "cxxabi_max_version": "1.3.12",
            },
            ee_suites: {},
        }
    ),
    "ubuntu-22.04-amd64": ExpectSuite(
        name="Ubuntu 22.04 (amd64)",
        manifest="fixtures/ubuntu-22.04-amd64.txt",
        tests={
            common_suites: {},
            libc_libcpp_suites: {
                "libc_max_version": "2.35",
                # gcc 11.2.0
                "libcxx_max_version": "3.4.29",
                "cxxabi_max_version": "1.3.13",
            },
            ee_suites: {},
        }
    ),
    "debian-10-amd64": ExpectSuite(
        name="Debian 10 (amd64)",
        manifest="fixtures/debian-10-amd64.txt",
        tests={
            common_suites: {},
            libc_libcpp_suites: {
                "libc_max_version": "2.28",
                # gcc 8.3.0
                "libcxx_max_version": "3.4.25",
                "cxxabi_max_version": "1.3.11",
            },
            ee_suites: {},
        }
    ),
    "debian-11-amd64": ExpectSuite(
        name="Debian 11 (amd64)",
        manifest="fixtures/debian-11-amd64.txt",
        tests={
            common_suites: {},
            libc_libcpp_suites: {
                "libc_max_version": "2.31",
                # gcc 10.2.1
                "libcxx_max_version": "3.4.28",
                "cxxabi_max_version": "1.3.12",
            },
            ee_suites: {},
        }
    ),
    "docker-image": ExpectSuite(
        name="Generic Docker Image",
        manifest=None,
        tests={
            docker_suites: {},
        }
    ),
}

# populate arm64 and fips suites from amd64 suites

for target in list(targets.keys()):
    if target.split("-")[0] in ("alpine", "ubuntu", "debian", "amazonlinux", "el9"):
        e = deepcopy(targets[target])
        e.manifest = e.manifest.replace("-amd64.txt", "-arm64.txt")
        # Ubuntu 22.04 (arm64)
        e.name = e.name.replace("(amd64)", "(arm64)")
        e.tests[arm64_suites] = {}

        # TODO: cross compiled aws2023 uses rpath instead of runpath
        if target == "amazonlinux-2023-amd64":
            e.use_rpath = True

        # ubuntu-22.04-arm64
        targets[target.replace("-amd64", "-arm64")] = e
    
    if target in ("el8-amd64", "el9-amd64", "ubuntu-20.04-amd64", "ubuntu-22.04-amd64"):
        e = deepcopy(targets[target])
        e.manifest = e.manifest.replace("-amd64.txt", "-amd64-fips.txt")
        # Ubuntu 22.04 (amd64) FIPS
        e.name = e.name + " FIPS"
        e.tests[ee_suites]["fips"] = True

        # ubuntu-22.04-amd64-fips
        targets[target + "-fips"] = e

