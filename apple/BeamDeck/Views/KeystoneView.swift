import SwiftUI

struct KeystoneShape: Equatable {
    static let rectangle = KeystoneShape(corners: [.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])
    var corners: [CGPoint]

    init(corners: [CGPoint]) { self.corners = corners }

    init?(raw: Any?) {
        guard let values = (raw as? [String: Any])?["corners"] as? [[Double]],
              values.count == 4, values.allSatisfy({ $0.count == 2 }) else { return nil }
        corners = values.map { CGPoint(x: $0[0], y: $0[1]) }
        guard isValid else { return nil }
    }

    var wire: [String: Any] { ["mode": "manual", "corners": corners.map { [Double($0.x), Double($0.y)] }] }

    var isValid: Bool {
        guard corners.count == 4, corners.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            return false
        }
        return corners.indices.allSatisfy { i in
            let a = corners[i], b = corners[(i + 1) % 4], c = corners[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            return cross >= 0.006 && hypot(b.x - a.x, b.y - a.y) >= 0.09
        }
    }

    func replacing(_ index: Int, with point: CGPoint) -> Self? {
        var result = self
        result.corners[index] = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        return result.isValid ? result : nil
    }
}

@MainActor
private final class KeystoneEditor: ObservableObject {
    @Published private(set) var draft = KeystoneShape.rectangle
    @Published private(set) var saved = KeystoneShape.rectangle
    @Published private(set) var problem: String?
    @Published private(set) var saving = false

    private var receiver: ProjectorConnection?
    private var socket: URLSessionWebSocketTask?
    private var preview: Task<Void, Never>?
    private var queued: KeystoneShape?
    private var generation = UUID()
    private var nextID = 0
    private var demo = false

    var canEdit: Bool { demo || receiver != nil }
    var dirty: Bool { draft != saved }

    func open(_ project: ProjectorConnection?, initial: KeystoneShape, demo: Bool) {
        close()
        receiver = project
        draft = initial
        saved = initial
        self.demo = demo
        problem = nil
    }

    func close() {
        generation = UUID()
        preview?.cancel()
        preview = nil
        queued = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        saving = false
        receiver = nil
    }

    func change(_ shape: KeystoneShape) {
        guard canEdit, !saving, shape != draft else { return }
        draft = shape
        guard !demo, let receiver else { return }
        queued = shape
        guard preview == nil else { return }
        let epoch = generation
        preview = Task { await sendPreviews(to: receiver, generation: epoch) }
    }

    private func sendPreviews(to receiver: ProjectorConnection, generation: UUID) async {
        defer { if generation == self.generation { preview = nil } }
        while let shape = queued, generation == self.generation, !Task.isCancelled {
            queued = nil
            do {
                let connection = try openSocket(receiver)
                _ = try await send(shape, commit: false, over: connection)
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                socket?.cancel()
                socket = nil
                problem = "Живий перегляд перервався. Можна зберегти поточний кадр."
                return
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    func save() async {
        guard canEdit, !saving, dirty else { return }
        if demo { saved = draft; return }
        guard let receiver else { return }
        saving = true
        problem = nil
        let epoch = generation
        let shape = draft
        queued = nil
        defer { if epoch == generation { saving = false } }
        await preview?.value
        guard epoch == generation, !Task.isCancelled else { return }
        do {
            do {
                let connection = try openSocket(receiver)
                try await commit(shape, over: connection)
            } catch let error as LinkError {
                throw error
            } catch {
                guard epoch == generation, !Task.isCancelled else { return }
                socket?.cancel()
                socket = nil
                _ = try await WiFi.post(receiver, path: "geometry", body: shape.wire)
            }
            guard epoch == generation, !Task.isCancelled else { return }
            saved = shape
            problem = nil
        } catch {
            if epoch == generation, !Task.isCancelled { problem = error.localizedDescription }
        }
    }

    private func openSocket(_ receiver: ProjectorConnection) throws -> URLSessionWebSocketTask {
        if let socket { return socket }
        let newlyOpened = try WiFi.socket(receiver, path: "geometry/live")
        socket = newlyOpened
        return newlyOpened
    }

    private func send(_ shape: KeystoneShape, commit: Bool, over socket: URLSessionWebSocketTask) async throws -> Int {
        nextID += 1
        let id = nextID
        var message = shape.wire
        message["id"] = id
        message["commit"] = commit
        let encoded = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: encoded, as: UTF8.self)))
        return id
    }

    private func commit(_ shape: KeystoneShape, over socket: URLSessionWebSocketTask) async throws {
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { socket.cancel() }
        }
        defer { watchdog.cancel() }
        let id = try await send(shape, commit: true, over: socket)
        while !Task.isCancelled {
            guard case .string(let text) = try await socket.receive(),
                  let reply = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  reply["id"] as? Int == id else { continue }
            if reply["accepted"] as? Bool == true { return }
            throw LinkError.remote(reply["code"] as? String ?? "rejected")
        }
        throw CancellationError()
    }
}

struct KeystoneView: View {
    @EnvironmentObject private var remote: Remote
    @StateObject private var editor = KeystoneEditor()
    @State private var corner = 0
    private let cornerNames = ["Верхній лівий", "Верхній правий", "Нижній правий", "Нижній лівий"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if editor.canEdit {
                    Button("Показати тестову сітку", systemImage: "squareshape.split.3x3") {
                        remote.send("open", ["destination": "grid"])
                    }
                    .buttonStyle(.bordered)
                    .disabled(remote.demo)
                    plot
                    Picker("Кут", selection: $corner) {
                        ForEach(cornerNames.indices, id: \.self) { index in Text(cornerNames[index]).tag(index) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        precisionSlider(horizontal: true)
                        precisionSlider(horizontal: false)
                    }
                    .disabled(editor.saving)
                    HStack {
                        Button("Скинути") { editor.change(.rectangle) }.buttonStyle(.bordered)
                        Spacer()
                        Button(editor.saving ? "Збереження…" : "Зберегти") { Task { await editor.save() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!editor.dirty || editor.saving)
                    }
                    if let problem = editor.problem {
                        Text(problem).foregroundStyle(.red).font(.footnote)
                    }
                    Text("Кути змінюються наживо в тестовій сітці, програвачі Agent і під час трансляції iPhone. Натисни «Зберегти», щоб залишити правки.")
                        .foregroundStyle(.secondary).font(.footnote)
                } else {
                    ContentUnavailableView("Потрібен Agent через Wi-Fi", systemImage: "wifi.slash",
                                           description: Text("Під’єднай телефон і приймач BeamDeck до однієї локальної мережі."))
                }
                if remote.firmware {
                    Button("Відкрити системну трапецію", systemImage: "trapezoid.and.line.vertical") {
                        remote.firmwareCommand(.init("Трапеція", 11, 12))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Трапеція")
        .task(id: remote.projectOverWiFi) {
            editor.open(remote.projectOverWiFi, initial: KeystoneShape(raw: remote.status.raw["geometry"]) ?? .rectangle,
                        demo: remote.demo)
        }
        .onDisappear { editor.close() }
    }

    private var plot: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 25, dy: 25)
            let points = editor.draft.corners.map { point in
                CGPoint(x: bounds.minX + point.x * bounds.width, y: bounds.minY + point.y * bounds.height)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.surface)
                Canvas { context, _ in
                    let outline = Path { path in path.move(to: points[0]); points.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath() }
                    context.fill(outline, with: .color(.accentColor.opacity(0.10)))
                    context.stroke(outline, with: .color(.accentColor), lineWidth: 2)
                    var mesh = Path()
                    for i in 1...3 {
                        let t = CGFloat(i) / 4
                        mesh.move(to: interpolate(points[0], points[1], t))
                        mesh.addLine(to: interpolate(points[3], points[2], t))
                        mesh.move(to: interpolate(points[0], points[3], t))
                        mesh.addLine(to: interpolate(points[1], points[2], t))
                    }
                    context.stroke(mesh, with: .color(.accentColor.opacity(0.45)), lineWidth: 1)
                }
                .accessibilityHidden(true)
                ForEach(points.indices, id: \.self) { index in
                    Circle()
                        .fill(index == corner ? Color.accentColor : Color.primary)
                        .frame(width: 19, height: 19)
                        .frame(width: 48, height: 48)
                        .contentShape(.circle)
                        .position(points[index])
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("keystone-plot"))
                            .onChanged { drag in
                                corner = index
                                guard bounds.width > 0, bounds.height > 0 else { return }
                                let x = (drag.location.x - bounds.minX) / bounds.width
                                let y = (drag.location.y - bounds.minY) / bounds.height
                                if let shape = editor.draft.replacing(index, with: CGPoint(x: x, y: y)) { editor.change(shape) }
                            })
                        .accessibilityHidden(true)
                }
            }
            .coordinateSpace(name: "keystone-plot")
            .disabled(editor.saving)
        }
        .aspectRatio(1.48, contentMode: .fit)
        .frame(minHeight: 200)
    }

    private func precisionSlider(horizontal: Bool) -> some View {
        let point = editor.draft.corners[corner]
        let value = Binding<Double>(get: { Double(horizontal ? point.x : point.y) }, set: { amount in
            let current = editor.draft.corners[corner]
            let adjusted = horizontal ? CGPoint(x: amount, y: current.y) : CGPoint(x: current.x, y: amount)
            if let shape = editor.draft.replacing(corner, with: adjusted) { editor.change(shape) }
        })
        return Slider(value: value, in: 0...1, step: 0.01) {
            Text(horizontal ? "Горизонталь" : "Вертикаль")
        }
    }

    private func interpolate(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
