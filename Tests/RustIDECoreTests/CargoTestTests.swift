import Foundation
import Testing
@testable import RustIDECore

@Suite struct CargoTestReportTests {
    static let output = """
           Compiling hello v0.1.0 (/p/hello)
            Finished `test` profile [unoptimized + debuginfo] target(s) in 0.40s
             Running unittests src/main.rs (target/debug/deps/hello-1a2b3c)

        running 3 tests
        test tests::greets ... ok
        test tests::slow ... ignored, needs network
        test tests::math::adds ... FAILED

        failures:

        ---- tests::math::adds stdout ----

        thread 'tests::math::adds' panicked at src/main.rs:20:9:
        assertion `left == right` failed
          left: 3
         right: 4

        failures:
            tests::math::adds

        test result: FAILED. 1 passed; 1 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.00s

             Running tests/api.rs (target/debug/deps/api-9f8e)

        running 1 test
        test round_trip ... ok

        test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

           Doc-tests hello

        running 1 test
        test src/lib.rs - add (line 3) ... ok
        """

    @Test func parsesSuitesStatusesAndFailureOutput() {
        var report = CargoTestReport()
        Self.output.split(separator: "\n", omittingEmptySubsequences: false).forEach { report.consume(line: String($0)) }
        #expect(report.tests.map(\.name) == ["tests::greets", "tests::slow", "tests::math::adds", "round_trip", "src/lib.rs - add (line 3)"])
        #expect(report.tests.map(\.suite) == ["unittests src/main.rs", "unittests src/main.rs", "unittests src/main.rs",
                                              "tests/api.rs", "doc-tests hello"])
        #expect((report.passed, report.failed, report.skipped) == (3, 1, 1))
        let failed = report.tests[2]
        #expect(failed.output.contains("panicked at src/main.rs:20:9") && failed.output.contains("right: 4"))
        #expect(!failed.output.contains("failures:"))
        #expect(failed.depth == 2 && failed.shortName == "adds")
        #expect(report.buildOutput.contains("Compiling hello"))
    }

    @Test func keepsCompileErrorsAsBuildOutput() {
        var report = CargoTestReport()
        for line in ["error[E0308]: mismatched types", " --> src/main.rs:2:18", "error: could not compile `hello`"] {
            report.consume(line: line)
        }
        #expect(report.tests.isEmpty && report.buildOutput.contains("E0308"))
    }
}

@Suite struct RustTestFinderTests {
    static let source = """
        fn helper() -> i32 { 1 }

        #[test]
        fn top_level() {
            assert_eq!(helper(), 1); // fn not_a_test() {}
        }

        #[cfg(test)]
        mod tests {
            use super::*;

            #[test]
            fn adds() {
                let s = "}"; // braces in strings don't count
                assert!(s.len() == 1);
            }

            mod nested {
                #[tokio::test]
                async fn awaits() {}

                #[test]
                #[should_panic(expected = "boom")]
                fn panics() { panic!("boom") }
            }

            fn not_a_test() {}
        }

        mod decl;
        """

    @Test func findsTestsWithModulePaths() {
        let tests = RustTestFinder.testFunctions(in: Self.source)
        #expect(tests.map(\.path) == ["top_level", "tests::adds", "tests::nested::awaits", "tests::nested::panics"])
        #expect(tests.map(\.line) == [3, 12, 19, 23])
        let ns = Self.source as NSString
        #expect(RustTestFinder.enclosingTest(in: Self.source, at: ns.range(of: "assert!(s.len()").location)?.path == "tests::adds")
        #expect(RustTestFinder.enclosingTest(in: Self.source, at: ns.range(of: "fn helper").location) == nil)
        #expect(ns.substring(with: tests[3].range).hasPrefix("#[test]\n        #[should_panic"))
    }

    @Test func derivesFileModulePaths() {
        let root = "/p/app"
        #expect(RustTestFinder.modulePath(ofFile: "/p/app/src/main.rs", packageRoot: root) == "")
        #expect(RustTestFinder.modulePath(ofFile: "/p/app/src/lib.rs", packageRoot: root) == "")
        #expect(RustTestFinder.modulePath(ofFile: "/p/app/src/net/http.rs", packageRoot: root) == "net::http")
        #expect(RustTestFinder.modulePath(ofFile: "/p/app/src/net/mod.rs", packageRoot: root) == "net")
        #expect(RustTestFinder.modulePath(ofFile: "/p/app/src/bin/tool.rs", packageRoot: root) == "")
        #expect(RustTestFinder.modulePath(ofFile: "/p/app/tests/api.rs", packageRoot: root) == "")
        #expect(RustTestFinder.join("net", "tests::x") == "net::tests::x")
    }

    @Test func picksTestTargetFlags() {
        let metadata = CargoMetadata(workspaceRoot: "/w", targetDirectory: "/w/target", packages: [
            CargoPackage(name: "app", manifestPath: "/w/app/Cargo.toml", features: [], targets: [
                CargoTarget(package: "app", name: "app", kind: .lib, srcPath: "/w/app/src/lib.rs"),
                CargoTarget(package: "app", name: "app", kind: .bin, srcPath: "/w/app/src/main.rs"),
                CargoTarget(package: "app", name: "api", kind: .test, srcPath: "/w/app/tests/api.rs"),
            ]),
            CargoPackage(name: "cli", manifestPath: "/w/cli/Cargo.toml", features: [], targets: [
                CargoTarget(package: "cli", name: "cli", kind: .bin, srcPath: "/w/cli/src/main.rs"),
            ]),
        ])
        #expect(RustTestFinder.targetArguments(forFile: "/w/app/src/net.rs", in: metadata) == ["-p", "app", "--lib"])
        #expect(RustTestFinder.targetArguments(forFile: "/w/app/src/main.rs", in: metadata) == ["-p", "app", "--bin", "app"])
        #expect(RustTestFinder.targetArguments(forFile: "/w/app/tests/api.rs", in: metadata) == ["-p", "app", "--test", "api"])
        #expect(RustTestFinder.targetArguments(forFile: "/w/cli/src/args.rs", in: metadata) == ["-p", "cli", "--bin", "cli"])
        #expect(RustTestFinder.targetArguments(forFile: "/elsewhere/x.rs", in: metadata).isEmpty)
    }
}
