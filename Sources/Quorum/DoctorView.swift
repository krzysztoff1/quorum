import SwiftUI
import QuorumCore

struct DoctorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Doctor").font(.title2.bold())
            engineSection
            if let preflight = model.preflight { claudeSection(preflight) }
            HStack {
                Button("Check again") { model.refreshEngine() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Engine candidates").font(.headline)
            ForEach(model.engine.doctorRows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: row.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(row.ok ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func claudeSection(_ preflight: PreflightResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code").font(.headline)
            Label(preflight.message,
                  systemImage: preflight.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(preflight.ok ? .green : .red)
                .font(.callout)
        }
    }
}
