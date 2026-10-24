import SwiftUI

/// Creates or edits a smart set.
struct SmartSetEditor: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: SmartSet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.smartSet(withID: draft.id) == nil ? "Neues Smart Set" : "Smart Set bearbeiten")
                .font(.title2.bold())

            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 6) {
                Text("Schriften, die")
                Picker("", selection: $draft.matchAll) {
                    Text("alle").tag(true)
                    Text("mindestens eine").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Text("der folgenden Bedingungen erfüllen:")
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach($draft.rules) { $rule in
                    SmartRuleRow(rule: $rule, canRemove: draft.rules.count > 1) {
                        draft.rules.removeAll { $0.id == rule.id }
                    }
                }
                Button {
                    draft.rules.append(SmartRule())
                } label: {
                    Label("Bedingung hinzufügen", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }

            Text("Trifft derzeit auf \(store.matchingRecords(for: draft).count) Schriften zu.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    store.saveSmartSet(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

private struct SmartRuleRow: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var rule: SmartRule
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $rule.field) {
                ForEach(SmartField.allCases) { field in
                    Text(field.label).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .onChange(of: rule.field) { _, field in
                if !field.operators.contains(rule.op) { rule.op = field.operators[0] }
                rule.value = ""
            }

            Picker("", selection: $rule.op) {
                ForEach(rule.field.operators) { op in
                    Text(op.label(for: rule.field)).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 170)

            valueField

            if let unit = rule.field.unit {
                Text(unit).foregroundStyle(.secondary)
            }

            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
        }
    }

    @ViewBuilder
    private var valueField: some View {
        switch rule.field.valueKind {
        case .text:
            TextField("Text", text: $rule.value)
                .textFieldStyle(.roundedBorder)
        case .number:
            TextField("Zahl", text: $rule.value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Spacer(minLength: 0)
        case .set:
            Picker("", selection: $rule.value) {
                Text("Set wählen").tag("")
                ForEach(store.foldersByPath + store.regularSetsByPath) { set in
                    Text(store.displayPath(of: set)).tag(set.id.uuidString)
                }
            }
            .labelsHidden()
        case .none:
            Spacer(minLength: 0)
        }
    }
}
