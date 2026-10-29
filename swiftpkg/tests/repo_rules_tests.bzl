"""Tests for `repo_rules` module."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//swiftpkg/internal:bazel_target_mods.bzl", "bazel_target_mods")
load("//swiftpkg/internal:pkg_ctxs.bzl", "pkg_ctxs")
load("//swiftpkg/internal:pkginfos.bzl", "pkginfos")
load("//swiftpkg/internal:repo_rules.bzl", "repo_rules")

def _download_artifacts_test(ctx):
    """download_artifacts downloads remote binary artifacts"""
    env = unittest.begin(ctx)

    calls = {"download_and_extract": [], "execute": [], "read": []}

    # buildifier: disable=unused-variable
    def _download_and_extract(url, output, sha256 = "", auth = {}):
        calls["download_and_extract"].append(struct(
            auth = auth,
            output = output,
            sha256 = sha256,
            url = url,
        ))
        return struct(success = True)

    # buildifier: disable=unused-variable
    def _execute(args, environment = {}, quiet = True):
        calls["execute"].append(args)
        return struct(return_code = 0, stdout = "", stderr = "")

    # buildifier: disable=unused-variable
    def _read(path, watch = "auto"):
        calls["read"].append(struct(path = path, watch = watch))
        return ""

    build_file_label = "//some/pkg:BUILD.custom"
    repository_ctx = struct(
        attr = struct(
            build_file = build_file_label,
            netrc = "auth.netrc",
        ),
        download_and_extract = _download_and_extract,
        execute = _execute,
        name = "bzlmodmangled~test_pkg",
        read = _read,
    )

    pkg_info = struct(
        name = "TestPkg",
        path = "",
        products = [],
        targets = [
            struct(
                artifact_download_info = struct(
                    checksum = "abc123",
                    url = "https://example.com/Artifact.zip",
                ),
                path = "remote/archive/Artifact.zip",
                type = "binary",
            ),
            struct(
                artifact_download_info = None,
                path = "Local.xcframework",
                type = "binary",
            ),
            struct(
                artifact_download_info = struct(
                    checksum = "def456",
                    url = "https://example.com/Source.zip",
                ),
                path = "remote/archive/Source.zip",
                type = "regular",
            ),
        ],
        url = "https://github.com/example/test-pkg",
        version = "1.0.0",
    )
    pkg_ctx = struct(pkg_info = pkg_info, bazel_target_mods = [])

    repo_rules.download_artifacts(repository_ctx, pkg_ctx)

    asserts.equals(
        env,
        [struct(path = "auth.netrc", watch = "no")],
        calls["read"],
        "the configured netrc should be read for download auth",
    )
    asserts.equals(
        env,
        [
            struct(
                auth = {},
                output = "remote/archive/Artifact.zip",
                sha256 = "abc123",
                url = "https://example.com/Artifact.zip",
            ),
        ],
        calls["download_and_extract"],
        "only remote binary artifacts should be downloaded",
    )

    return unittest.end(env)

download_artifacts_test = unittest.make(
    _download_artifacts_test,
)

def _gen_build_files_with_build_file_test(ctx):
    """When build_file is set, gen_build_files should use it and skip \
    generation."""
    env = unittest.begin(ctx)

    # Track that template was called with the expected arguments.
    calls = {"template": []}

    def _template(path, label):
        calls["template"].append(struct(path = path, label = label))

    build_file_label = "//some/pkg:BUILD.custom"
    repository_ctx = struct(
        attr = struct(
            bazel_target_mods = "",
            build_file = build_file_label,
            system_sdk_deps = True,
            binary_target_deps = True,
        ),
        template = _template,
    )

    # Pass None for pkg_ctx. If the early return is bypassed, the function
    # will fail trying to access pkg_ctx.pkg_info, making the failure obvious.
    repo_rules.gen_build_files(repository_ctx, None)

    asserts.equals(
        env,
        1,
        len(calls["template"]),
        "template should be called exactly once",
    )
    asserts.equals(
        env,
        "BUILD.bazel",
        calls["template"][0].path,
        "template output path should be BUILD.bazel",
    )
    asserts.equals(
        env,
        build_file_label,
        calls["template"][0].label,
        "template should receive the build_file label",
    )

    return unittest.end(env)

gen_build_files_with_build_file_test = unittest.make(
    _gen_build_files_with_build_file_test,
)

def _gen_build_files_without_build_file_test(ctx):
    """When build_file is None, gen_build_files should proceed with normal \
    generation."""
    env = unittest.begin(ctx)

    # Track calls to template — it should NOT be called.
    calls = {"file": [], "template": []}

    def _template(path, label):
        calls["template"].append(struct(path = path, label = label))

    # buildifier: disable=unused-variable
    def _file(path, content = "", executable = False, legacy_utf8 = False):
        calls["file"].append(struct(path = path, content = content))

    # buildifier: disable=unused-variable
    def _execute(args, environment = {}, quiet = True):
        # Return empty results for find commands (license file search).
        return struct(return_code = 0, stdout = "", stderr = "")

    repository_ctx = struct(
        attr = struct(bazel_target_mods = "", build_file = None),
        name = "bzlmodmangled~test_pkg",
        template = _template,
        file = _file,
        execute = _execute,
    )

    pkg_info = struct(
        name = "TestPkg",
        url = "https://github.com/example/test-pkg",
        version = "1.0.0",
        path = "",
        targets = [],
        products = [],
    )
    pkg_ctx = struct(
        pkg_info = pkg_info,
        system_sdk_deps = True,
        binary_target_deps = True,
        bazel_target_mods = [bazel_target_mods.new(
            bazel_target_mods.verbs.set,
            "package_info.rspm",
            "package_version",
            value = "overridden",
        )],
    )

    repo_rules.gen_build_files(repository_ctx, pkg_ctx)
    asserts.true(env, 'package_version = "overridden"' in calls["file"][-1].content, calls["file"][-1].content)
    asserts.false(env, 'package_version = "1.0.0"' in calls["file"][-1].content)

    asserts.equals(
        env,
        0,
        len(calls["template"]),
        "template should not be called when build_file is None",
    )

    # Verify that the normal generation path wrote a BUILD file.
    asserts.true(
        env,
        len(calls["file"]) > 0,
        "file should be called to write the generated BUILD file",
    )

    return unittest.end(env)

gen_build_files_without_build_file_test = unittest.make(
    _gen_build_files_without_build_file_test,
)

def _binary_inference_generation_test(ctx):
    env = unittest.begin(ctx)

    def _generate(enabled, manual, interface_basename = "arm64-apple-ios.swiftinterface"):
        files = []
        targets = [
            pkginfos.new_target(
                name = name,
                type = "binary",
                c99name = name,
                module_type = "BinaryTarget",
                path = name + ".xcframework",
                sources = [],
                dependencies = [],
                repo_name = "@swiftpkg_binary_test",
            )
            for name in ["Importer", "Provider"]
        ]
        pkg_info = pkginfos.new(
            name = "BinaryTest",
            path = "",
            tools_version = "5.9",
            url = "https://example.com/binary-test",
            version = "1.0.0",
            dependencies = [],
            platforms = [],
            products = [],
            targets = targets,
        )
        pkg_ctx = pkg_ctxs.new(
            pkg_info = pkg_info,
            repo_name = "@swiftpkg_binary_test",
            binary_target_deps = enabled,
            target_deps = {"Importer": manual} if manual else {},
        )

        # buildifier: disable=unused-variable
        def _execute(args, environment = {}, quiet = True):
            if args[0] == "test":
                return struct(return_code = 0, stdout = "", stderr = "")
            if args[0] == "find":
                base = args[3]
                if base == ".":
                    found = []
                elif base.endswith(".xcframework"):
                    name = base.removesuffix(".xcframework")
                    found = [base + "/ios-arm64/" + name + ".framework"]
                elif base.endswith(".framework"):
                    name = base.split("/")[-1].removesuffix(".framework")
                    if "*.swiftinterface" in args:
                        module_name = "DependencyModule" if name == "Provider" else name
                        found = [base + "/Modules/" + module_name + ".swiftmodule/" + interface_basename]
                    else:
                        found = [base + "/" + name]
                else:
                    found = []
                return struct(return_code = 0, stdout = "\n".join(found), stderr = "")
            if args[0] == "od":
                return struct(return_code = 0, stdout = " 21 3c 61 72 63 68 3e 0a\n", stderr = "")
            return struct(return_code = 0, stdout = "", stderr = "")

        def _read(path):
            return "import DependencyModule\n" if "Importer.framework" in path else ""

        # buildifier: disable=unused-variable
        def _file(path, content = "", executable = False, legacy_utf8 = False):
            files.append(content)

        repository_ctx = struct(
            attr = struct(build_file = None, bazel_target_mods = ""),
            name = "swiftpkg_binary_test",
            execute = _execute,
            read = _read,
            file = _file,
        )
        repo_rules.gen_build_files(repository_ctx, pkg_ctx)
        return files[-1]

    enabled = _generate(True, [])
    disabled = _generate(False, [])
    manual = _generate(True, ["Provider"])
    absolute_manual = _generate(True, ["//:Provider"])
    invalid_basename = _generate(True, [], interface_basename = "arm64.swiftinterface")
    asserts.true(env, 'deps = [":Provider.rspm"]' in enabled, enabled)
    asserts.false(env, 'deps = [":Provider.rspm"]' in disabled, disabled)
    asserts.equals(env, 1, manual.count('":Provider.rspm"'))
    asserts.false(env, 'deps = [":Provider.rspm"]' in invalid_basename, invalid_basename)
    asserts.true(env, 'deps = ["//:Provider.rspm"]' in absolute_manual, absolute_manual)
    return unittest.end(env)

binary_inference_generation_test = unittest.make(_binary_inference_generation_test)

def _make_files_read_only_test(ctx):
    env = unittest.begin(ctx)

    calls = []

    def execute(args, quiet = False):
        calls.append(struct(args = args, quiet = quiet))
        return struct(
            return_code = 0,
            stdout = "",
            stderr = "",
        )

    repository_ctx = struct(
        execute = execute,
        os = struct(name = "linux"),
    )

    repo_rules.make_files_read_only(
        repository_ctx,
        "/tmp/swiftpkg",
        enabled = True,
    )

    asserts.equals(env, 1, len(calls), "expected a single chmod invocation")
    asserts.equals(
        env,
        [
            "find",
            "/tmp/swiftpkg",
            "-type",
            "f",
            "-exec",
            "chmod",
            "a-w",
            "{}",
            "+",
        ],
        calls[0].args,
        "expected the repository files to be marked read-only",
    )
    asserts.true(env, calls[0].quiet, "expected chmod invocation to be quiet")

    return unittest.end(env)

make_files_read_only_test = unittest.make(_make_files_read_only_test)

def _make_files_read_only_disabled_noop_test(ctx):
    env = unittest.begin(ctx)

    calls = []

    def execute(args, quiet = False):
        calls.append(struct(args = args, quiet = quiet))
        return struct(
            return_code = 0,
            stdout = "",
            stderr = "",
        )

    repository_ctx = struct(
        execute = execute,
    )

    repo_rules.make_files_read_only(
        repository_ctx,
        "/tmp/swiftpkg",
        enabled = False,
    )

    asserts.equals(env, [], calls, "expected no chmod invocation when disabled")

    return unittest.end(env)

make_files_read_only_disabled_noop_test = unittest.make(
    _make_files_read_only_disabled_noop_test,
)

def repo_rules_test_suite():
    return unittest.suite(
        "repo_rules_tests",
        download_artifacts_test,
        gen_build_files_with_build_file_test,
        gen_build_files_without_build_file_test,
        binary_inference_generation_test,
        make_files_read_only_disabled_noop_test,
        make_files_read_only_test,
    )
