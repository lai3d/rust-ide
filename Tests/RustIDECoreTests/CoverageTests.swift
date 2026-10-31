import Foundation
import Testing
@testable import RustIDECore

@Suite struct CoverageTests {
    @Test func parsesProfiles() throws {
        #expect(CoverageReport.modulePath(goMod: "// c\nmodule example.com/app\n\ngo 1.22\n") == "example.com/app")
        let profile = """
            mode: set
            example.com/app/calc.go:3.24,5.2 1 1
            example.com/app/calc.go:7.24,8.13 1 1
            example.com/app/calc.go:8.13,10.3 1 0
            example.com/app/calc.go:11.2,11.10 1 1
            example.com/app/sub/x.go:3.13,3.15 0 0
            other.org/lib/y.go:1.1,2.2 1 1
            """
        let report = CoverageReport.parse(profile, modulePath: "example.com/app", root: "/r")
        let calc = try #require(report.files["/r/calc.go"])
        #expect(calc.statements == 4 && calc.coveredStatements == 3 && calc.percent == 75)
        #expect(calc.lines[2] == true && calc.lines[8] == false && calc.lines[7] == true)  // line 8 shared: covered wins
        #expect(report.files["/r/sub/x.go"] != nil)
        #expect(report.files.keys.allSatisfy { $0.hasPrefix("/r/") })  // other modules skipped
        #expect(report.percent == 75)
    }
}
