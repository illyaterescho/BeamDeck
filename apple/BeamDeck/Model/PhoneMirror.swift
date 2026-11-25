#if os(iOS)
import CoreImage
import ImageIO
import ScreenCaptureKit
import SwiftUI

@available(iOS 27.0, *)
@MainActor
final class PhoneMirror: NSObject, ObservableObject, SCContentSharingPickerObserver, SCStreamDelegate {
    enum Phase { case idle, choosing, starting, sharing }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var problem: String?

    private var attempt = UUID()
    private var projector: ProjectorConnection?
    private var sessionID: String?
    private var capture: SCStream?
    private var output: MirrorOutput?
    private var heartbeat: Task<Void, Never>?

    func choose(_ receiver: ProjectorConnection) {
        guard phase == .idle else { return }
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else {
            problem = "iPhone зараз не може відкрити вибір екрана."
            return
        }
        problem = nil
        projector = receiver
        phase = .choosing
        picker.defaultConfiguration = SCContentSharingPickerConfiguration()
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func stop() {
        guard phase != .idle else { return }
        let old = capture
        let endpoint = projector
        let id = sessionID
        closePicker()
        attempt = UUID()
        heartbeat?.cancel()
        heartbeat = nil
        output?.stop()
        output = nil
        capture = nil
        projector = nil
        sessionID = nil
        phase = .idle
        Task {
            async let stopCapture: Void? = try? old?.stopCapture()
            if let endpoint, let id {
                _ = try? await WiFi.post(endpoint, path: "mirror/stop", body: ["id": id])
            }
            _ = await stopCapture
        }
    }

    private func closePicker() {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    private func start(_ filter: SCContentFilter) async {
        guard phase == .choosing, let projector else { return }
        phase = .starting
        let current = attempt
        do {
            let result = try await WiFi.post(projector, path: "mirror/start", body: [:])
            guard let id = result["id"] as? String else { throw LinkError.protocolMismatch }
            guard current == attempt else {
                _ = try? await WiFi.post(projector, path: "mirror/stop", body: ["id": id])
                return
            }
            sessionID = id
            let configuration = SCStreamConfiguration()
            let size = filter.contentRect.size
            let longest = max(size.width, size.height)
            if longest > 0, longest.isFinite {
                configuration.width = max(2, Int((384 * size.width / longest).rounded()) * 2)
                configuration.height = max(2, Int((384 * size.height / longest).rounded()) * 2)
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            let output = MirrorOutput(projector: projector, id: id)
            self.output = output
            capture = stream
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            guard current == attempt else { return }
            phase = .sharing
            heartbeat = Task { await keepAlive(projector, id: id, attempt: current) }
        } catch {
            guard current == attempt else { return }
            fail(error)
        }
    }

    private func keepAlive(_ receiver: ProjectorConnection, id: String, attempt: UUID) async {
        var failures = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, attempt == self.attempt else { return }
            do {
                _ = try await WiFi.post(receiver, path: "mirror/keepalive", body: ["id": id])
                failures = 0
            } catch {
                guard !Task.isCancelled, attempt == self.attempt else { return }
                failures += 1
                if failures >= 2 || error as? LinkError == .remote("mirror_ended") {
                    fail(error)
                    return
                }
            }
        }
    }

    private func fail(_ error: Error) {
        stop()
        if error as? LinkError == .remote("launch_blocked") {
            problem = "Відкрий BeamDeck на проєкторі й запусти трансляцію знову."
        } else {
            problem = error.localizedDescription
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            if phase == .choosing { stop() }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in await start(filter) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            if phase == .choosing { fail(error) }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            if capture === stream { fail(error) }
        }
    }
}

@available(iOS 27.0, *)
private final class MirrorOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "ua.beamdeck.mirror.frames", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let projector: ProjectorConnection
    private let id: String
    private var sending: Task<Void, Never>?
    private var stopped = false
    private var nextFrame = ContinuousClock.now

    init(projector: ProjectorConnection, id: String) {
        self.projector = projector
        self.id = id
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.sending?.cancel()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sending == nil, .now >= nextFrame,
              let pixels = sample.imageBuffer else { return }
        let frameInfo = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first
        if let status = frameInfo?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }

        var image = CIImage(cvPixelBuffer: pixels)
        if let orientation = frameInfo?[.videoOrientation] as? UInt32,
           let direction = CGImagePropertyOrientation(rawValue: orientation) {
            image = image.oriented(direction)
        }
        let scale = min(1, 768 / max(image.extent.width, image.extent.height))
        image = image.transformed(by: .init(scaleX: scale, y: scale))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.68]),
              jpeg.count <= 384 * 1024 else { return }
        nextFrame = .now.advanced(by: .milliseconds(82))
        sending = Task {
            try? await WiFi.mirrorFrame(projector, id: id, jpeg: jpeg)
            queue.async { self.sending = nil }
        }
    }
}
#endif
