import SwiftUI

/// Add, edit, reorder and delete the composer's saved prompts.
struct PromptEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Prompts").font(.title3.weight(.semibold))
            HSplitView {
                List(selection: $selected) {
                    ForEach(model.settings.prompts) { p in
                        Text(p.title).lineLimit(1).tag(p.id)
                    }
                    .onMove { model.settings.prompts.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minWidth: 200)
                if let i = model.settings.prompts.firstIndex(where: { $0.id == selected }) {
                    Form {
                        TextField("Title", text: $model.settings.prompts[i].title)
                        Toggle("Only in project threads", isOn: $model.settings.prompts[i].forProjects)
                        TextEditor(text: $model.settings.prompts[i].text)
                            .font(.body)
                            .frame(minHeight: 160)
                    }
                    .padding(8)
                    .frame(minWidth: 320)
                } else {
                    Text("Select a prompt").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack {
                Button { 
                    let p = SavedPrompt(title: "New prompt", text: "")
                    model.settings.prompts.append(p)
                    selected = p.id
                } label: { Image(systemName: "plus").accessibilityLabel("Add prompt") }
                Button {
                    model.settings.prompts.removeAll { $0.id == selected }
                    selected = nil
                } label: { Image(systemName: "minus").accessibilityLabel("Delete prompt") }
                .disabled(selected == nil)
                Button("Restore Defaults") { model.settings.prompts = SavedPrompt.defaults; selected = nil }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 640, height: 420)
    }
}
