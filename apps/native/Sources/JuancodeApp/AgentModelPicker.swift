import SwiftUI
import JuancodeCore

/// Model IDs go straight to the CLI; nil preserves the user's configured default.
struct AgentModelPicker: View {
    let provider: ProviderId
    @Binding var selection: String?
    @State private var custom = false

    private var models: [String] {
        switch provider {
        case .claude: return ["opus", "sonnet", "haiku"]
        case .codex: return ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"]
        default: return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Model", selection: Binding(
                get: { custom ? "custom" : selection ?? "" },
                set: { value in
                    custom = value == "custom"
                    selection = custom || value.isEmpty ? nil : value
                }
            )) {
                Text("CLI default").tag("")
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
                Text("Custom…").tag("custom")
            }
            if custom {
                TextField("Model ID", text: Binding(
                    get: { selection ?? "" },
                    set: { value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        selection = trimmed.isEmpty ? nil : trimmed
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }
}
