import AVFoundation
import Foundation

final class RemoteAudioRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    enum State {
        case idle, starting, recording, stopping
    }

    private static let deviceUID = "SiriRemoteMic_UID"
    private static let packetLogger = "/Applications/PacketLogger.app/Contents/Resources/packetlogger"
    private let captureQueue = DispatchQueue(label: "com.hypervibe.remoteAudio")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var onStopped: (() -> Void)?

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?
    var onError: ((String) -> Void)?

    static let recordingsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music", isDirectory: true)
        .appendingPathComponent("HyperVibe Recordings", isDirectory: true)

    func start() {
        guard state == .idle else { return }
        guard AVCaptureDevice(uniqueID: Self.deviceUID) != nil else {
            onError?("Siri Remote Mic is unavailable. Install the SiriRemoteForge microphone components and Apple’s PacketLogger, then try again.")
            return
        }

        guard FileManager.default.isExecutableFile(atPath: Self.packetLogger) else {
            onError?("Put Apple’s PacketLogger.app in /Applications to enable Siri Remote audio.")
            return
        }

        state = .starting
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.state == .starting else { return }
                    if granted {
                        self.beginCapture()
                    } else {
                        self.finish(error: Self.permissionError)
                    }
                }
            }
        default:
            finish(error: Self.permissionError)
        }
    }

    private static let permissionError = "Allow HyperVibe under System Settings → Privacy & Security → Microphone, then try again."

    private func beginCapture() {
        captureQueue.async {
            do {
                guard let device = AVCaptureDevice(uniqueID: Self.deviceUID), device.isConnected,
                      device.hasMediaType(.audio) else {
                    throw CaptureError.inputUnavailable
                }
                let input = try AVCaptureDeviceInput(device: device)
                let session = AVCaptureSession()
                let output = AVCaptureAudioFileOutput()
                guard session.canAddInput(input), session.canAddOutput(output),
                      AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.wav) else {
                    throw CaptureError.cannotStart
                }
                session.addInput(input)
                session.addOutput(output)

                let folder = Self.recordingsFolder
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                let suffix = UUID().uuidString.prefix(8)
                let url = folder.appendingPathComponent("Siri Remote \(formatter.string(from: Date())) \(suffix).wav")

                session.startRunning()
                guard session.isRunning else { throw CaptureError.cannotStart }
                self.session = session
                self.output = output
                output.startRecording(to: url, outputFileType: .wav, recordingDelegate: self)
            } catch {
                DispatchQueue.main.async { self.finish(error: error.localizedDescription) }
            }
        }
    }

    func stop() {
        guard state == .recording else { return }
        state = .stopping
        captureQueue.async { self.output?.stopRecording() }
    }

    func finishBeforeQuitting(_ completion: @escaping () -> Void) -> Bool {
        guard state != .idle else { return false }
        onStopped = completion
        stop()
        return true
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.state = .recording
            if self.onStopped != nil { self.stop() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        captureQueue.async {
            self.session?.stopRunning()
            self.session = nil
            self.output = nil

            // AVFoundation can report an interruption even when it finalized a playable clip.
            let written = error == nil || (error as NSError?)?
                .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
            let hasAudio = written && ((try? AVAudioFile(forReading: fileURL).length) ?? 0) > 0
            if !hasAudio { try? FileManager.default.removeItem(at: fileURL) }
            DispatchQueue.main.async {
                self.finish(error: hasAudio ? nil : (error?.localizedDescription ?? "No audio was recorded."))
            }
        }
    }

    private func finish(error: String?) {
        state = .idle
        if let completion = onStopped {
            onStopped = nil
            if let error { rmDebug("Remote microphone recording failed: \(error)") }
            completion()
        } else if let error {
            onError?(error)
        }
    }

    private enum CaptureError: LocalizedError {
        case inputUnavailable, cannotStart

        var errorDescription: String? {
            switch self {
            case .inputUnavailable: return "Siri Remote Mic disconnected before recording started."
            case .cannotStart: return "Could not start WAV recording from Siri Remote Mic."
            }
        }
    }
}
