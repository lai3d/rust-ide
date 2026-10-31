import RustIDECore
import SwiftUI

/// Results of the last `cargo test` run: test list on the left, selected output on the right.
struct TestsPanel: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        let report = workspace.testReport
        if report.tests.isEmpty && !workspace.isRunning {
            VStack(spacing: 8) {
                Text(report.buildOutput.isEmpty ? "No test results yet." : "Build failed — see Output.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Run All Tests (⌘U)") { workspace.runTests(.all) }
                    Button("Run Package (⌃⌘U)") { workspace.runActivePackageTests() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    summary(report)
                    Divider()
                    List(selection: $workspace.selectedTestID) {
                        if let coverage = workspace.coverage, !coverage.files.isEmpty {
                            Section("Coverage by file") {
                                ForEach(coverage.files.sorted { $0.value.percent < $1.value.percent }, id: \.key) { path, file in
                                    HStack {
                                        Text(workspace.displayPath(path)).lineLimit(1).truncationMode(.head)
                                        Spacer()
                                        Text(String(format: "%.0f%%", file.percent)).monospacedDigit()
                                            .foregroundStyle(file.percent >= 70 ? .green : .orange)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { workspace.openFile(URL(fileURLWithPath: path)) }
                                }
                            }
                        }
                        ForEach(report.tests) { test in
                            TestRow(test: test)
                                .tag(test.id)
                                .contextMenu {
                                    Button("Go to Test") { workspace.revealTest(named: test.name) }
                                    Button("Run Again") { workspace.rerun(test) }
                                }
                                .onTapGesture(count: 2) { workspace.revealTest(named: test.name) }
                        }
                    }
                    .listStyle(.plain)
                }
                .frame(minWidth: 220, idealWidth: 300)
                TestOutput(output: combinedOutput(report))
                    .frame(minWidth: 240)
            }
        }
    }

    /// The selected test's captured output (cargo only prints it for failures).
    private func combinedOutput(_ report: CargoTestReport) -> String? {
        guard let selected = report.tests.first(where: { $0.id == workspace.selectedTestID }) else { return nil }
        if !selected.output.isEmpty { return selected.output }
        return switch selected.status {
        case .passed: "Passed. (cargo test shows output only for failures; add -- --nocapture in a terminal to see more.)"
        case .skipped: "Ignored."
        default: ""
        }
    }

    private func summary(_ report: CargoTestReport) -> some View {
        HStack(spacing: 10) {
            Text(workspace.testRunTitle).fontWeight(.semibold).lineLimit(1)
            Spacer()
            if workspace.isRunning { ProgressView().controlSize(.small) }
            Label("\(report.passed)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Label("\(report.failed)", systemImage: "xmark.circle.fill").foregroundStyle(report.failed > 0 ? .red : .secondary)
            if report.skipped > 0 {
                Label("\(report.skipped)", systemImage: "forward.circle.fill").foregroundStyle(.secondary)
            }
            if let coverage = workspace.coverage {
                Text(String(format: "Coverage %.1f%%", coverage.percent))
                    .foregroundStyle(coverage.percent >= 70 ? .green : .orange)
                    .help("Line coverage of the last run (cargo llvm-cov)")
            }
        }
        .font(.callout.monospacedDigit())
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct TestRow: View {
    let test: TestResult

    var body: some View {
        HStack(spacing: 6) {
            TestStatusIcon(status: test.status)
            Text(test.name).lineLimit(1).truncationMode(.head)
            Spacer()
            Text(test.suite).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(test.name + " — " + test.suite)
    }
}

struct TestStatusIcon: View {
    let status: TestResult.Status

    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini).frame(width: 14)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "forward.circle.fill").foregroundStyle(.secondary)
        }
    }
}

/// A test's output; `file.rs:12:5` references are clickable.
private struct TestOutput: View {
    @Environment(Workspace.self) private var workspace
    let output: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if let output {
                    ForEach(Array(output.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                            id: \.offset) { _, line in
                        lineView(String(line))
                    }
                } else {
                    Text("Select a test to see its output.").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        if let ref = OutputReferences.find(in: line).first {
            Button { workspace.revealOutputReference(file: ref.file, line: ref.line, column: ref.column) } label: {
                Text(line).underline().foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        } else {
            Text(line.isEmpty ? " " : line)
                .foregroundStyle(line.contains("panicked at") || line.hasPrefix("assertion") ? .red : .primary)
        }
    }
}
