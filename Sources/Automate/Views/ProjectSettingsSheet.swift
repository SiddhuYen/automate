import SwiftUI
import AutomateCore

/// Defaults for new threads in one project (a throwaway repo can use Bypass; your main one, Opus on high).
struct ProjectSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var project: Project

    var body: some View {
        let s = model.settings
        VStack(alignment: .leading, spacing: 14) {
            Text("\(project.name) settings").font(.title3.weight(.semibold))
            Text("Defaults for new threads in this project. Existing threads keep their own choices.")
                .foregroundStyle(.secondary)
            Form {
                Picker("Model", selection: $project.model) {
                    Text("App default (\(s.defaultModel.capitalized))").tag(String?.none)
                    ForEach(ComposerView.models, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                }
                Picker("Effort", selection: $project.effort) {
                    Text("App default (\(s.defaultEffort))").tag(String?.none)
                    ForEach(ComposerView.efforts, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("Permissions", selection: $project.permissionMode) {
                    Text("App default (\(s.defaultPermission.label))").tag(PermissionMode?.none)
                    ForEach(PermissionMode.allCases) { Text($0.label).tag(PermissionMode?.some($0)) }
                }
                Picker("Own git branch", selection: $project.worktreeByDefault) {
                    Text("App default (\(s.worktreeByDefault ? "on" : "off"))").tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                }
                if project.permissionMode == .bypassPermissions {
                    Text("Bypass lets Claude do anything in this folder without asking. Only use it for throwaway work.")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.updateProject(project)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
