"""Tests for `swift_files` module."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//swiftpkg/internal:swift_files.bzl", "swift_files")

def _has_objc_directive_test(ctx):
    env = unittest.begin(ctx)

    tests = [
        struct(
            msg = "has @objc",
            contents = """\
@objc(OIFooSwiftVersionInfo)
public class FooSwiftVersionInfo: NSObject {
    @objc(myVersion) public func version() -> String {
        let verInfo = VersionInfo()
        return verInfo.version
    }
}
""",
            exp = True,
        ),
        struct(
            msg = "has @objcMembers",
            contents = """\
@objcMembers public class FooSwiftVersionInfo: NSObject {
    public func version() -> String {
        let verInfo = VersionInfo()
        return verInfo.version
    }
}
""",
            exp = True,
        ),
        struct(
            msg = "no directives",
            contents = """\
public class FooSwiftVersionInfo: NSObject {
    public func version() -> String {
        let verInfo = VersionInfo()
        return verInfo.version
    }
}
""",
            exp = False,
        ),
    ]
    for t in tests:
        actual = swift_files.has_objc_directive(t.contents)
        asserts.equals(env, t.exp, actual, t.msg)

    return unittest.end(env)

has_objc_directive_test = unittest.make(_has_objc_directive_test)

def _has_import_test(ctx):
    env = unittest.begin(ctx)

    tests = [
        struct(
            msg = "empty content",
            imp = "XCTest",
            content = "",
            exp = False,
        ),
        struct(
            msg = "single import",
            imp = "XCTest",
            content = """\
import XCTest
""",
            exp = True,
        ),
        struct(
            msg = "import at end of content",
            imp = "XCTest",
            content = "import XCTest",
            exp = True,
        ),
        struct(
            msg = "similar import, suffix differs",
            imp = "XCTest",
            content = "import XCTestOverlay",
            exp = False,
        ),
        struct(
            msg = "similar import, prefix differs",
            imp = "XCTest",
            content = "_import XCTest",
            exp = False,
        ),
        struct(
            msg = "multiple imports, keep looking",
            imp = "XCTest",
            content = """\
import XCTestOverlay
import XCTest
""",
            exp = True,
        ),
        struct(
            msg = "import inside a single-line comment",
            imp = "XCTest",
            content = """\
// import XCTest
""",
            exp = False,
        ),
        struct(
            msg = "import inside a multi-line comment",
            imp = "XCTest",
            content = """\
/* The following should be ignored:
import XCTest
*/
""",
            exp = False,
        ),
        struct(
            msg = "import inside a single-line string",
            imp = "XCTest",
            content = """\
let ignoreMe = " import XCTest "
""",
            exp = False,
        ),
        struct(
            msg = "import inside a multi-line string",
            imp = "XCTest",
            content = '''\
let ignoreMe = """
import XCTest
"""
''',
            exp = False,
        ),
        struct(
            msg = "invalid import and valid import",
            imp = "XCTest",
            content = """\
// import XCTest
import XCTest
""",
            exp = True,
        ),
        struct(
            msg = "inside conditional compilation",
            imp = "XCTest",
            content = """\
#if DEBUG
    #if !canImport(ObjectiveC)
      import Chicken
    #endif
    import XCTest
#endif
""",
            exp = False,
        ),
    ]
    for t in tests:
        actual = swift_files.has_import(t.content, t.imp)
        asserts.equals(env, t.exp, actual, t.msg)

    return unittest.end(env)

has_import_test = unittest.make(_has_import_test)

def _collect_imports_test(ctx):
    env = unittest.begin(ctx)
    contents = '''\
import Foundation
@testable import XCTest
public import struct Foundation.Date
#if DEBUG
import First
#elseif canImport(Second)
import Second
#else
#if OTHER
import Third
#endif
#endif
import Foundation
// import Ignored
/* outer /* import Hidden */ import StillHidden */
let text = "import StringIgnored"
let raw = #"import RawIgnored"#
let multiline = """
import MultilineIgnored
"""
let rawMultiline = #"""
import RawMultilineIgnored
"""#
import Final
'''
    actual = swift_files.collect_imports(contents)
    expected = [
        struct(module_name = "Foundation", line_number = 1, is_conditional = False),
        struct(module_name = "XCTest", line_number = 2, is_conditional = False),
        struct(module_name = "Foundation", line_number = 3, is_conditional = False),
        struct(module_name = "First", line_number = 5, is_conditional = True),
        struct(module_name = "Second", line_number = 7, is_conditional = True),
        struct(module_name = "Third", line_number = 10, is_conditional = True),
        struct(module_name = "Foundation", line_number = 13, is_conditional = False),
        struct(module_name = "Final", line_number = 24, is_conditional = False),
    ]
    asserts.equals(env, expected, actual)
    asserts.equals(env, [], swift_files.collect_imports("let x = canImport(Foo)\n_import Bar\nimported Baz"))
    edge_contents = '''\
import Foundation; import Dispatch
#if\tDEBUG
import /* a
comment */ XCTest
#endif
import
  `ModuleName`.Thing
let raw = #"escaped \\#" import Hidden"#
import Visible
'''
    asserts.equals(env, [
        struct(module_name = "Foundation", line_number = 1, is_conditional = False),
        struct(module_name = "Dispatch", line_number = 1, is_conditional = False),
        struct(module_name = "XCTest", line_number = 3, is_conditional = True),
        struct(module_name = "ModuleName", line_number = 6, is_conditional = False),
        struct(module_name = "Visible", line_number = 9, is_conditional = False),
    ], swift_files.collect_imports(edge_contents))
    literal_contents = '''\
let interpolation = "\\(render("import Hidden"))"
let regex = /import RegexHidden/
let array = [/import ArrayHidden/]
let punctuated = /(import PunctuationHidden)/
let escapedParen = /\\(import EscapedHidden/
let extended = #/
import ExtendedHidden
/#
import Visible
'''
    asserts.equals(env, [
        struct(module_name = "Visible", line_number = 9, is_conditional = False),
    ], swift_files.collect_imports(literal_contents))
    asserts.equals(env, [
        struct(module_name = "Visible", line_number = 2, is_conditional = False),
    ], swift_files.collect_imports("let value = /customPrefix\nimport Visible"))
    return unittest.end(env)

collect_imports_test = unittest.make(_collect_imports_test)

def swift_files_test_suite():
    return unittest.suite(
        "swift_files_tests",
        has_objc_directive_test,
        has_import_test,
        collect_imports_test,
    )
