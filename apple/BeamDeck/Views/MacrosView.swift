import SwiftUI

/// One-tap macro buttons on the remote screen.
struct MacroBar: View {
    @EnvironmentObject private var remote: Remote
    @EnvironmentObject private var store: MacroStore
    @State private var editing: Macro?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Макроси").font(.headline)
                Spacer()
                Button { editing = Macro(name: "") } label: { Label("Новий", systemImage: "plus") }
                    .font(.subheadline)
            }
            if store.macros.isEmpty {
                Text("Запишіть шлях кнопками, наприклад до трапеції чи режиму зображення, і відкривайте його одним дотиком.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.macros) { macro in
                            Button { store.play(macro, on: remote) } label: {
                                Label(macro.name, systemImage: store.playing == macro.id ? "stop.fill" : macro.symbol)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 40)
                                    .background(store.playing == macro.id ? Color.accentColor.opacity(0.25) : Color.surfaceRaised,
                                                in: .capsule)
                            }
                            .buttonStyle(PressStyle())
                            .contextMenu {
                                Button("Змінити", systemImage: "pencil") { editing = macro }
                                Button("Видалити", systemImage: "trash", role: .destructive) { store.delete(macro.id) }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.surface, in: .rect(cornerRadius: 22))
        .sheet(item: $editing) { MacroEditor(macro: $0) }
    }
}

/// Full list, for renaming, reordering and deleting.
struct MacrosListView: View {
    @EnvironmentObject private var remote: Remote
    @EnvironmentObject private var store: MacroStore
    @State private var editing: Macro?

    var body: some View {
        List {
            Section {
                ForEach(store.macros) { macro in
                    HStack {
                        Button { store.play(macro, on: remote) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(macro.name).foregroundStyle(.primary)
                                    Text(macro.steps.map(MacroStore.label).joined(separator: " → "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            } icon: {
                                Image(systemName: store.playing == macro.id ? "stop.fill" : macro.symbol)
                            }
                        }
                        Spacer()
                        Button { editing = macro } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                    }
                }
                .onDelete { offsets in offsets.map { store.macros[$0].id }.forEach(store.delete) }
                .onMove(perform: store.move)
                Button { editing = Macro(name: "") } label: { Label("Новий макрос", systemImage: "plus") }
            } footer: {
                Text("Макрос натискає записані кнопки по черзі. Голосом: «макрос» і назва, наприклад «макрос трапеція».")
            }
        }
        .navigationTitle("Макроси")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
        .sheet(item: $editing) { MacroEditor(macro: $0) }
    }
}

/// Records a macro live: every key goes to the projector so you see where you are, and is added to the steps.
struct MacroEditor: View {
    @EnvironmentObject private var remote: Remote
    @EnvironmentObject private var store: MacroStore
    @Environment(\.dismiss) private var dismiss
    @State var macro: Macro
    @State private var live = true

    private let symbols = ["wand.and.rays", "trapezoid.and.line.vertical", "sun.max", "paintpalette", "film",
                           "tv", "rectangle.on.rectangle", "speaker.wave.2", "gearshape", "star"]
    private let pauses = [300, 500, 800, 1200, 2000]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Назва, наприклад «Трапеція»", text: $macro.name)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(symbols, id: \.self) { symbol in
                                Image(systemName: symbol)
                                    .frame(width: 38, height: 38)
                                    .background(macro.symbol == symbol ? Color.accentColor.opacity(0.25) : Color.surfaceRaised,
                                                in: .circle)
                                    .onTapGesture { macro.symbol = symbol }
                            }
                        }
                    }
                    Picker("Пауза між кнопками", selection: $macro.pauseMs) {
                        ForEach(pauses, id: \.self) { Text(String(format: "%.1f с", Double($0) / 1000)).tag($0) }
                    }
                }

                Section {
                    Toggle("Натискати на проєкторі під час запису", isOn: $live)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(MacroStore.keys, id: \.key) { item in
                            Button {
                                macro.steps.append(item.key)
                                if live { remote.key(item.key) } else { remote.haptic += 1 }
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: item.symbol).font(.system(size: 17, weight: .semibold))
                                    Text(item.label).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                                }
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .background(Color.surfaceRaised, in: .rect(cornerRadius: 12))
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } header: {
                    Text("Запис")
                } footer: {
                    Text("Спершу поверніть проєктор на головний екран кнопкою «Додому», а потім натискайте шлях до потрібного меню.")
                }

                Section {
                    if macro.steps.isEmpty {
                        Text("Поки порожньо").foregroundStyle(.secondary)
                    }
                    ForEach(Array(macro.steps.enumerated()), id: \.offset) { index, step in
                        Label("\(index + 1). \(MacroStore.label(step))", systemImage: MacroStore.symbol(step))
                    }
                    .onDelete { macro.steps.remove(atOffsets: $0) }
                    .onMove { macro.steps.move(fromOffsets: $0, toOffset: $1) }
                    if !macro.steps.isEmpty {
                        Button("Перевірити макрос", systemImage: "play.fill") { store.play(macro, on: remote) }
                        Button("Очистити", systemImage: "trash", role: .destructive) { macro.steps.removeAll() }
                    }
                } header: {
                    Text("Кроки (\(macro.steps.count))")
                }
            }
            .navigationTitle(macro.name.isEmpty ? "Новий макрос" : macro.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Скасувати") { store.stop(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Зберегти") {
                        var saved = macro
                        if saved.name.trimmingCharacters(in: .whitespaces).isEmpty { saved.name = "Макрос \(store.macros.count + 1)" }
                        store.stop()
                        store.save(saved)
                        dismiss()
                    }
                    .disabled(macro.steps.isEmpty)
                }
            }
        }
    }
}
