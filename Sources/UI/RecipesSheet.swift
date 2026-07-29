import SwiftUI
import AppKit

/// «Рецепты» — pick a saved prompt-lens (follow-up email, minutes, PRD, coaching…) and generate a
/// finished artifact from the meeting. Left = recipe list (+ your own), right = the generated output.
struct RecipesSheet: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject private var recipes = RecipeStore.shared
    let material: () -> String          // recomputed per run so a live meeting isn't run on stale data
    var onClose: () -> Void

    @State private var selected: Recipe?
    @State private var output = ""
    @State private var running = false
    @State private var error: String?
    @State private var editing: Recipe?          // editor for a custom recipe (or a fresh one)
    @State private var showEditor = false
    @State private var copied = false
    @State private var tgSent = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.pLine)
            HStack(spacing: 0) {
                list.frame(width: 240)
                Divider().overlay(Color.pLine)
                result.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 520)
        .background(Color.pCanvas)
        .sheet(isPresented: $showEditor) {
            RecipeEditor(recipe: editing ?? Recipe(name: "", icon: "wand.and.stars", prompt: "")) { saved in
                recipes.upsert(saved)   // insert or update — the store figures out which
                showEditor = false
            } onDelete: {
                if let e = editing { deleteRecipe(e) }
                showEditor = false
            }
        }
    }

    private func deleteRecipe(_ r: Recipe) {
        recipes.remove(r.id)
        if selected?.id == r.id { selected = nil; output = ""; error = nil }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L("Рецепты", "Recipes")).font(PFont.heading).foregroundStyle(Color.pInk1)
            Text(L("готовые документы из встречи", "ready-made documents from your meeting")).font(PFont.secondary).foregroundStyle(Color.pInk3)
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(Color.pInk2)
                    .frame(width: 28, height: 28).background(Circle().fill(Color.pSelection)).contentShape(Circle())
            }.buttonStyle(.plain).accessibilityLabel(L("Закрыть", "Close"))
        }
        .padding(.horizontal, 20).frame(height: 56)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recipes.all) { r in recipeRow(r) }
                }.padding(8)
            }
            Divider().overlay(Color.pLine2)
            HStack(spacing: 8) {
                Button { editing = nil; showEditor = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(Color.pAccent)
                        Text(L("Свой рецепт", "Custom recipe")).font(PFont.secondary).foregroundStyle(Color.pInk1)
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if recipes.all.count < RecipeStore.builtins.count {
                    Button { recipes.restoreDefaults() } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 11)).foregroundStyle(Color.pInk3)
                    }.buttonStyle(.plain).help(L("Восстановить стандартные", "Restore defaults"))
                }
            }.padding(.horizontal, 12).frame(height: 40)
        }
        .background(Color.pRail)
    }

    @State private var hovered: UUID?

    private func recipeRow(_ r: Recipe) -> some View {
        let active = selected?.id == r.id
        let showActions = hovered == r.id || active
        return Button { run(r) } label: {
            HStack(spacing: 10) {
                Image(systemName: r.icon).font(.system(size: 13)).foregroundStyle(active ? Color.pInk1 : Color.pInk2).frame(width: 18)
                Text(r.name).font(PFont.secondary).foregroundStyle(Color.pInk1).lineLimit(1)
                Spacer(minLength: 4)
                if showActions {
                    Button { editing = r; showEditor = true } label: {
                        Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(Color.pInk3).frame(width: 22, height: 22).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(L("Редактировать", "Edit"))
                    Button { deleteRecipe(r) } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Color.pInk3).frame(width: 22, height: 22).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(L("Удалить", "Delete"))
                }
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? Color.pSelection : Color.clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(r.name)
        .onHover { hovered = $0 ? r.id : (hovered == r.id ? nil : hovered) }
    }

    @ViewBuilder private var result: some View {
        VStack(spacing: 0) {
            if running {
                Spacer(); PSpinner(size: 26)
                Text(L("Готовлю «\(selected?.name ?? "")»…", "Preparing \(selected?.name ?? "")…")).font(PFont.secondary).foregroundStyle(Color.pInk2).padding(.top, 12); Spacer()
            } else if let error {
                Spacer()
                EmptyHint(icon: "exclamationmark.triangle", title: L("Не получилось", "That didn't work"), subtitle: error)
                Button(L("Повторить", "Try again")) { if let s = selected { run(s) } }.buttonStyle(PBorderedButtonStyle()).padding(.top, 12)
                Spacer()
            } else if output.isEmpty {
                Spacer()
                EmptyHint(icon: "wand.and.stars", title: L("Выберите рецепт", "Choose a recipe"),
                          subtitle: L("Слева — готовые документы из этой встречи. Можно добавить свой.", "On the left are ready-made documents from this meeting. You can add your own."))
                Spacer()
            } else {
                ScrollView {
                    Text(output).font(.system(size: 13)).lineSpacing(3).foregroundStyle(Color.pInk1)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                Divider().overlay(Color.pLine2)
                HStack(spacing: 8) {
                    actionButton(copied ? L("Скопировано ✓", "Copied ✓") : L("Копировать", "Copy"), "doc.on.doc", tint: copied) { copy() }
                    actionButton(L("Поделиться", "Share"), "square.and.arrow.up") { share() }
                    if Telegram.isConfigured {
                        actionButton(tgSent ? L("Отправлено ✓", "Sent ✓") : L("В Telegram", "To Telegram"), "paperplane", tint: tgSent) { sendTelegram() }
                    }
                    Spacer()
                    actionButton(L("Обновить", "Regenerate"), "arrow.clockwise") { if let s = selected { run(s) } }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private func actionButton(_ title: String, _ icon: String, tint: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: icon); Text(title) }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(tint ? Color.pAccent : Color.pInk1)
                .padding(.horizontal, 12).frame(height: 30)
                .background(Color.pChrome).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pButtonBorder, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // MARK: Actions

    private func run(_ r: Recipe) {
        selected = r; error = nil; output = ""
        let mat = material().trimmingCharacters(in: .whitespacesAndNewlines)
        // No meeting/dictation content → a recipe has nothing to work on; running it would just make
        // the model echo/reformat the recipe's own instruction. Block with a clear message instead.
        guard mat.count >= 25 else {
            error = L("Нет материала: запишите встречу или выберите запись, затем соберите документ.",
                      "No material: record or pick a meeting first, then build the document.")
            return
        }
        running = true
        Task {
            do {
                let result = try await store.runRecipe(instruction: r.prompt, material: mat)
                await MainActor.run { output = result; running = false }
            } catch {
                let msg = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { self.error = msg; running = false }
            }
        }
    }
    private func sendTelegram() {
        guard !output.isEmpty else { return }
        let text = output
        Task {
            do {
                try await Telegram.send(text)
                await MainActor.run { tgSent = true }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run { tgSent = false }
            } catch {
                await MainActor.run { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }

    private func copy() {
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(output, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
    private func share() {
        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [output])
        picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
}

private struct EmptyHint: View {
    let icon: String; let title: String; let subtitle: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Color.pInk3)
            Text(title).font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
            Text(subtitle).font(PFont.secondary).foregroundStyle(Color.pInk3)
                .multilineTextAlignment(.center).frame(maxWidth: 280)
        }
    }
}

/// Add/edit a custom recipe.
private struct RecipeEditor: View {
    @State var recipe: Recipe
    var onSave: (Recipe) -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(recipe.name.isEmpty ? L("Новый рецепт", "New recipe") : L("Рецепт", "Recipe")).font(PFont.heading).foregroundStyle(Color.pInk1)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Название", "Name")).font(PFont.label).foregroundStyle(Color.pInk3)
                TextField(L("Напр. «Письмо инвестору»", "e.g. Investor update"), text: $recipe.name).textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 10).frame(height: 32).background(Color.pField)
                    .clipShape(RoundedRectangle(cornerRadius: PRadius.control))
                    .overlay(RoundedRectangle(cornerRadius: PRadius.control).strokeBorder(Color.pButtonBorder, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Инструкция (что сделать из встречи)", "Instruction (what to make from the meeting)")).font(PFont.label).foregroundStyle(Color.pInk3)
                TextEditor(text: $recipe.prompt).font(.system(size: 13)).foregroundStyle(Color.pInk1)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 140).background(Color.pField)
                    .clipShape(RoundedRectangle(cornerRadius: PRadius.control))
                    .overlay(RoundedRectangle(cornerRadius: PRadius.control).strokeBorder(Color.pButtonBorder, lineWidth: 1))
            }
            HStack {
                if !recipe.name.isEmpty {   // editing an existing recipe (any kind) → allow delete
                    Button { onDelete() } label: { Text(L("Удалить", "Delete")).foregroundStyle(Color.pDanger) }.buttonStyle(.plain).font(.system(size: 12))
                }
                Spacer()
                Button(L("Сохранить", "Save")) { onSave(recipe) }.buttonStyle(PPrimaryButtonStyle())
                    .disabled(recipe.name.trimmingCharacters(in: .whitespaces).isEmpty || recipe.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 440).background(Color.pCanvas)
    }
}
