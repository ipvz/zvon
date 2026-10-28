import SwiftUI

struct LLMHeadersEditor: View {
    let provider: LLMProvider
    let endpoint: String
    var didSave: () -> Void
    @State private var rows: [LLMHTTPHeader]
    @State private var saved: [LLMHTTPHeader]
    @State private var error: String?

    init(provider: LLMProvider, endpoint: String, didSave: @escaping () -> Void) {
        self.provider = provider; self.endpoint = endpoint; self.didSave = didSave
        let values = LLMHTTPHeaders.load(provider: provider, endpoint: endpoint)
        _rows = State(initialValue: values); _saved = State(initialValue: values)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Дополнительные HTTP-заголовки", "Additional HTTP headers")).font(PFont.secondaryStrong)
                Spacer()
                Button { rows.append(LLMHTTPHeader(name: "", value: "")); error = nil } label: {
                    Label(L("Добавить", "Add"), systemImage: "plus")
                }.buttonStyle(PBorderedButtonStyle()).disabled(rows.count >= 32)
                    .accessibilityLabel(L("Добавить HTTP-заголовок", "Add HTTP header"))
            }
            ForEach($rows) { $row in
                HStack(spacing: 10) {
                    TextField("X-Traffic-Class", text: $row.name)
                        .accessibilityLabel(L("Имя HTTP-заголовка", "HTTP header name"))
                    TextField("interactive", text: $row.value)
                        .accessibilityLabel(L("Значение HTTP-заголовка", "HTTP header value"))
                    Button { rows.removeAll { $0.id == row.id }; error = nil } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Color.pInk2)
                    }.buttonStyle(.plain).accessibilityLabel(L("Удалить HTTP-заголовок", "Remove HTTP header"))
                }
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Color.pDanger).fixedSize(horizontal: false, vertical: true) }
            HStack(alignment: .top) {
                Text(L("Только для этого провайдера и адреса. Значения хранятся в Keychain. Сохраните изменения перед проверкой связи.",
                       "Only for this provider and endpoint. Values are stored in Keychain. Save changes before testing the connection."))
                    .font(.system(size: 11)).foregroundStyle(Color.pInk3)
                Spacer(minLength: 16)
                if rows != saved {
                    Button(L("Сохранить заголовки", "Save headers")) {
                        do {
                            try LLMHTTPHeaders.save(rows, provider: provider, endpoint: endpoint)
                            rows = LLMHTTPHeaders.load(provider: provider, endpoint: endpoint)
                            saved = rows; error = nil; didSave()
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(PBorderedButtonStyle())
                }
            }
        }.padding(16)
        .background(Color.pField, in: RoundedRectangle(cornerRadius: PRadius.control))
        .overlay(RoundedRectangle(cornerRadius: PRadius.control).strokeBorder(Color.pButtonBorder, lineWidth: 1))
    }
}
