"""Tests for sibling binary target dependency inference."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//swiftpkg/internal:binary_target_deps.bzl", "binary_target_deps")

def _import(name, conditional = False):
    return struct(module_name = name, line_number = 1, is_conditional = conditional)

def _target(name, module, slice_imports, complete = True):
    slices = []
    for basename, imports in slice_imports:
        slices.append(struct(name = basename, interfaces = [struct(
            basename = basename + ".swiftinterface",
            path = name + "/" + basename + ".swiftinterface",
            imports = imports,
        )]))
    return struct(name = name, module_name = module, slices = slices, complete = complete)

def _infer_test(ctx):
    env = unittest.begin(ctx)
    provider = _target("DifferentTargetName", "DependencyModule", [
        ("arm64-apple-ios", []),
        ("arm64-apple-macos", []),
    ])
    importer = _target("Importer", "ImporterModule", [
        ("arm64-apple-ios", [_import("DependencyModule")]),
        ("arm64-apple-macos", [_import("DependencyModule")]),
    ])
    result = binary_target_deps.infer([importer, provider])
    asserts.equals(env, ["DifferentTargetName"], result.deps["Importer"])
    asserts.equals(env, [], result.diagnostics)

    conditional = _target("Conditional", "ConditionalModule", [
        ("arm64-apple-ios", [_import("DependencyModule", conditional = True)]),
    ])
    result = binary_target_deps.infer([conditional, provider])
    asserts.equals(env, [], result.deps["Conditional"])
    asserts.equals(env, 1, len(result.diagnostics))

    disagreement = _target("Disagreement", "DisagreementModule", [
        ("arm64-apple-ios", [_import("DependencyModule")]),
        ("arm64-apple-macos", []),
    ])
    result = binary_target_deps.infer([disagreement, provider])
    asserts.equals(env, [], result.deps["Disagreement"])
    asserts.equals(env, 1, len(result.diagnostics))

    missing_coverage = _target("ShortProvider", "DependencyModule", [
        ("arm64-apple-ios", []),
    ])
    result = binary_target_deps.infer([importer, missing_coverage])
    asserts.equals(env, [], result.deps["Importer"])
    asserts.equals(env, 1, len(result.diagnostics))

    result = binary_target_deps.infer([importer, provider, provider])
    asserts.equals(env, [], result.deps["Importer"])
    asserts.equals(env, 1, len(result.diagnostics))

    incomplete = _target("Incomplete", "DependencyModule", [("arm64-apple-ios", [])], complete = False)
    result = binary_target_deps.infer([importer, incomplete])
    asserts.equals(env, [], result.deps["Importer"])
    asserts.equals(env, 2, len(result.diagnostics))

    header_only = _target("HeaderOnly", None, [], complete = False)
    result = binary_target_deps.infer([importer, header_only])
    asserts.equals(env, [], result.deps["Importer"])
    asserts.equals(env, 1, len(result.diagnostics))
    return unittest.end(env)

infer_test = unittest.make(_infer_test)

def _cycle_subject_impl(ctx):
    first = _target("First", "FirstModule", [("arm64-apple-ios", [_import("SecondModule")])])
    second = _target("Second", "SecondModule", [("arm64-apple-ios", [] if ctx.attr.manual else [_import("FirstModule")])])
    binary_target_deps.infer([first, second], {"Second": ["First"]} if ctx.attr.manual else {})
    return []

_cycle_subject = rule(implementation = _cycle_subject_impl, attrs = {"manual": attr.bool()})

def _cycle_failure_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "First -> Second -> First")
    asserts.expect_failure(env, "First/arm64-apple-ios.swiftinterface:1")
    asserts.expect_failure(env, ctx.attr.last_edge)
    return analysistest.end(env)

_cycle_failure_test = analysistest.make(_cycle_failure_impl, expect_failure = True, attrs = {"last_edge": attr.string()})

def _cycle_test(name):
    _cycle_failure_test(name = name, target_under_test = ":binary_target_deps_cycle_subject", last_edge = "Second/arm64-apple-ios.swiftinterface:1")

def _manual_cycle_test(name):
    _cycle_failure_test(name = name, target_under_test = ":binary_target_deps_manual_cycle_subject", last_edge = "manual dependency")

def binary_target_deps_test_suite(name = "binary_target_deps_tests"):
    _cycle_subject(name = "binary_target_deps_cycle_subject", tags = ["manual"])
    _cycle_subject(name = "binary_target_deps_manual_cycle_subject", manual = True, tags = ["manual"])
    return unittest.suite(name, infer_test, _cycle_test, _manual_cycle_test)
