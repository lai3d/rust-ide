import Foundation
import Testing
@testable import RustIDECore

@Suite struct GoTestTests {
    @Test func aggregatesTestEvents() {
        var report = GoTestReport()
        let lines = [
            #"{"Action":"start","Package":"ex/p"}"#,
            #"{"Action":"run","Package":"ex/p","Test":"TestA"}"#,
            #"{"Action":"output","Package":"ex/p","Test":"TestA","Output":"=== RUN   TestA\n"}"#,
            #"{"Action":"pass","Package":"ex/p","Test":"TestA","Elapsed":0.01}"#,
            #"{"Action":"run","Package":"ex/p","Test":"TestB"}"#,
            #"{"Action":"run","Package":"ex/p","Test":"TestB/sub"}"#,
            #"{"Action":"output","Package":"ex/p","Test":"TestB/sub","Output":"    b_test.go:9: boom\n"}"#,
            #"{"Action":"fail","Package":"ex/p","Test":"TestB/sub","Elapsed":0}"#,
            #"{"Action":"fail","Package":"ex/p","Test":"TestB","Elapsed":0.02}"#,
            #"{"Action":"skip","Package":"ex/p","Test":"TestC"}"#,
            #"{"Action":"fail","Package":"ex/p","Elapsed":0.3}"#,
            "not json",
        ]
        lines.forEach { report.consume(line: $0) }
        #expect(report.tests.map(\.name) == ["TestA", "TestB", "TestB/sub", "TestC"])
        #expect(report.passed == 1 && report.failed == 2 && report.skipped == 1)
        #expect(report.tests[2].depth == 1 && report.tests[2].shortName == "sub")
        #expect(report.tests[2].output.contains("boom"))
        #expect(report.anyPackageFailed)
        #expect(report.buildOutput == "not json\n")
    }

    @Test func findsTestFunctions() {
        let source = """
            package p

            func TestAdd(t *testing.T) {
            \tx := 1
            }

            func Testify() {}
            func helper() {}
            func (s *S) TestMethod(t *testing.T) {}
            func BenchmarkAdd(b *testing.B) {}
            func Example() {}

            """
        let tests = GoTestFinder.testFunctions(in: source)
        #expect(tests.map(\.name) == ["TestAdd", "BenchmarkAdd", "Example"])
        #expect(tests.first?.line == 2)
        let insideAdd = (source as NSString).range(of: "x := 1").location
        #expect(GoTestFinder.enclosingTest(in: source, at: insideAdd) == "TestAdd")
        let insideHelper = (source as NSString).range(of: "helper").location + 10
        #expect(GoTestFinder.enclosingTest(in: source, at: insideHelper) == nil)
    }

    @Test func findsFileReferencesInOutput() {
        let refs = GoTestFinder.fileReferences(in: "    main_test.go:12: expected 3, got 4")
        #expect(refs.count == 1 && refs[0].file == "main_test.go" && refs[0].line == 12)
    }
}
