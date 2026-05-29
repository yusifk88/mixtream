import Flutter
import AVFoundation
import Accelerate
import Photos
import CoreImage

class VideoMixerPlugin: NSObject, FlutterPlugin {
    private var mainSession: AVCaptureSession?
    private var pipSession: AVCaptureSession?
    private var mainOutput: AVCaptureVideoDataOutput?
    private var pipOutput: AVCaptureVideoDataOutput?

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isRecording = false
    private var outputURL: URL?
    private var previewSink: FlutterEventSink?
    fileprivate var pipPreviewSink: FlutterEventSink?
    private var startTime: CMTime?

    // Pixel buffers
    private var mainPixelBuffer: CVPixelBuffer?
    private var pipPixelBuffer: CVPixelBuffer?

    // Portrait output: 720x1280
    private let outW = 720
    private let outH = 1280
    private let previewW = 180
    private let previewH = 320
    private let pipShadowDx: CGFloat = 3
    private let pipShadowDy: CGFloat = 7
    private let pipShadowBlur: CGFloat = 12

    // PiP config (normalized 0-1 from Flutter)
    private var pipNormX = 0.82
    private var pipNormY = 0.11
    private var pipNormW = 0.17
    private var pipNormH = 0.22
    private var pipZoom: CGFloat = 1.0
    private var pipCornerRadius: CGFloat = 14
    private var pipShadowAlpha: Int = 70
    private var pipEnabled = true
    private var useMainFront = false

    // Photo overlay config (multi-photo)
    private struct PhotoOverlay {
        let id: String
        let image: CGImage
        var normX: CGFloat
        var normY: CGFloat
        var normW: CGFloat
        var normH: CGFloat
    }
    private var photoOverlays: [PhotoOverlay] = []

    // Reusable output buffer (720x1280 BGRA)
    private var outputBuffer: CVPixelBuffer?

    // Preview throttle (every 3rd frame)
    private var previewFrameCount = 0
    private var pipPreviewFrameCount = 0

    private let queue = DispatchQueue(label: "com.mixstream.videomixer", qos: .userInitiated)

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = VideoMixerPlugin()
        let method = FlutterMethodChannel(name: "com.example.learningflutter/video_mixer", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: method)

        let event = FlutterEventChannel(name: "com.example.learningflutter/mixer_preview", binaryMessenger: registrar.messenger())
        event.setStreamHandler(instance)

        let pipEvent = FlutterEventChannel(name: "com.example.learningflutter/mixer_pip_preview", binaryMessenger: registrar.messenger())
        pipEvent.setStreamHandler(PipPreviewStreamHandler(plugin: instance))
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startRecording":
            let args = call.arguments as? [String: Any] ?? [:]
            startRecording(args: args, result: result)
        case "stopRecording": stopRecording(result: result)
        case "addPhoto":
            if let args = call.arguments as? [String: Any],
               let id = args["id"] as? String,
               let photoData = args["data"] as? FlutterStandardTypedData,
               let uiImage = UIImage(data: photoData.data)?.cgImage {
                let normX = CGFloat(args["normX"] as? Double ?? 0.0)
                let normY = CGFloat(args["normY"] as? Double ?? 0.0)
                let normW = CGFloat(args["normW"] as? Double ?? 0.0)
                let normH = CGFloat(args["normH"] as? Double ?? 0.0)
                self.photoOverlays.append(PhotoOverlay(
                    id: id, image: uiImage,
                    normX: normX, normY: normY,
                    normW: normW, normH: normH
                ))
                print("Mixer: addPhoto \(id) (\(self.photoOverlays.count) total)")
            }
            result(true)
        case "updatePipZoom":
            if let zoom = call.arguments as? [String: Any], let z = zoom["zoom"] as? Double {
                pipZoom = max(1.0, CGFloat(z))
            }
            result(true)
        case "updatePipConfig":
            if let args = call.arguments as? [String: Any] {
                pipNormX = args["pipNormX"] as? Double ?? pipNormX
                pipNormY = args["pipNormY"] as? Double ?? pipNormY
                pipNormW = args["pipNormW"] as? Double ?? pipNormW
                pipNormH = args["pipNormH"] as? Double ?? pipNormH
                pipZoom = CGFloat(args["pipZoom"] as? Double ?? Double(pipZoom))
                pipCornerRadius = CGFloat(args["pipCornerRadius"] as? Double ?? Double(pipCornerRadius))
                pipShadowAlpha = args["pipShadowAlpha"] as? Int ?? pipShadowAlpha
                pipEnabled = args["pipEnabled"] as? Bool ?? pipEnabled
                // Multi-photo: update positions by ID, reuse images
                if let photosArg = args["photos"] as? [[String: Any]] {
                    var newOverlays: [PhotoOverlay] = []
                    let oldById = Dictionary(uniqueKeysWithValues: self.photoOverlays.map { ($0.id, $0) })
                    for p in photosArg {
                        let id = p["id"] as? String ?? ""
                        if let existing = oldById[id] {
                            newOverlays.append(PhotoOverlay(
                                id: id, image: existing.image,
                                normX: CGFloat(p["normX"] as? Double ?? 0.0),
                                normY: CGFloat(p["normY"] as? Double ?? 0.0),
                                normW: CGFloat(p["normW"] as? Double ?? 0.0),
                                normH: CGFloat(p["normH"] as? Double ?? 0.0)
                            ))
                        }
                    }
                    self.photoOverlays = newOverlays
                    print("Mixer: updatePipConfig \(self.photoOverlays.count) photos (images reused)")
                }
            }
            result(true)
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func startRecording(args: [String: Any], result: @escaping FlutterResult) {
        guard !isRecording else { result(["textureId": NSNull()]); return }

        pipNormX = args["pipNormX"] as? Double ?? 0.82
        pipNormY = args["pipNormY"] as? Double ?? 0.11
        pipNormW = args["pipNormW"] as? Double ?? 0.17
        pipNormH = args["pipNormH"] as? Double ?? 0.22
        pipZoom = CGFloat(args["pipZoom"] as? Double ?? 1.0)
        pipCornerRadius = CGFloat(args["pipCornerRadius"] as? Double ?? 14)
        pipShadowAlpha = args["pipShadowAlpha"] as? Int ?? 70
        useMainFront = args["useMainFront"] as? Bool ?? false

        // Photo overlays (multi-photo)
        self.photoOverlays.removeAll()
        if let photosArg = args["photos"] as? [[String: Any]] {
            for p in photosArg {
                guard let photoData = p["data"] as? FlutterStandardTypedData,
                      let uiImage = UIImage(data: photoData.data)?.cgImage else { continue }
                let id = p["id"] as? String ?? ""
                self.photoOverlays.append(PhotoOverlay(
                    id: id, image: uiImage,
                    normX: CGFloat(p["normX"] as? Double ?? 0.0),
                    normY: CGFloat(p["normY"] as? Double ?? 0.0),
                    normW: CGFloat(p["normW"] as? Double ?? 0.0),
                    normH: CGFloat(p["normH"] as? Double ?? 0.0)
                ))
            }
        }

        isRecording = true
        result(["textureId": NSNull()])

        queue.async {
            self.setupAndStart()
        }
    }

    private func setupAndStart() {
        let fm = FileManager.default
        let fileName = "MixStream_\(Int(Date().timeIntervalSince1970)).mp4"
        let url = fm.temporaryDirectory.appendingPathComponent(fileName)
        try? fm.removeItem(at: url)
        outputURL = url

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW, AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoExpectedSourceFrameRateKey: 30,
            ]
        ]

        guard let aw = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        assetWriter = aw

        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vi.expectsMediaDataInRealTime = true
        videoInput = vi

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: attrs)

        guard aw.canAdd(vi) else { return }
        aw.add(vi)

        CVPixelBufferCreate(kCFAllocatorDefault, outW, outH,
                            kCVPixelFormatType_32BGRA, nil, &outputBuffer)

        startCameras()
    }

    private func startCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video, position: .unspecified
        )

        if useMainFront {
            if let front = discovery.devices.first(where: { $0.position == .front }) {
                mainSession = captureSession(camera: front, label: "main")
            }
            if let back = discovery.devices.first(where: { $0.position == .back }) {
                pipSession = captureSession(camera: back, label: "pip")
            }
        } else {
            if let back = discovery.devices.first(where: { $0.position == .back }) {
                mainSession = captureSession(camera: back, label: "main")
            }
            if let front = discovery.devices.first(where: { $0.position == .front }) {
                pipSession = captureSession(camera: front, label: "pip")
            }
        }

        mainSession?.startRunning()
        pipSession?.startRunning()

        previewFrameCount = 0
        pipPreviewFrameCount = 0
    }

    private func captureSession(camera: AVCaptureDevice, label: String) -> AVCaptureSession {
        let session = AVCaptureSession()
        session.sessionPreset = label == "main" ? .hd1280x720 : .medium

        guard let input = try? AVCaptureDeviceInput(device: camera) else { return session }
        guard session.canAddInput(input) else { return session }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else { return session }
        session.addOutput(output)

        if label == "main" { mainOutput = output }
        else { pipOutput = output }

        if let conn = output.connection(with: .video) {
            // Only set videoOrientation for PiP camera (main camera rotation is handled by vImageRotate)
            if label == "pip", conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            if label == "pip", conn.isVideoMirroringSupported { conn.isVideoMirrored = true }
            if label == "main", useMainFront, conn.isVideoMirroringSupported { conn.isVideoMirrored = true }
        }

        return session
    }

    private func stopRecording(result: @escaping FlutterResult) {
        isRecording = false
        queue.async { [weak self] in
            guard let self = self else { DispatchQueue.main.async { result(nil) }; return }
            self.mainSession?.stopRunning(); self.mainSession = nil
            self.pipSession?.stopRunning(); self.pipSession = nil

            self.mainPixelBuffer = nil
            self.pipPixelBuffer = nil
            self.outputBuffer = nil
            self.startTime = nil
            self.photoOverlays.removeAll()

            self.videoInput?.markAsFinished()
            guard let aw = self.assetWriter, let url = self.outputURL else {
                self.assetWriter = nil
                self.videoInput = nil
                self.pixelBufferAdaptor = nil
                DispatchQueue.main.async { result(nil) }; return
            }
            aw.finishWriting {
                self.assetWriter = nil
                self.videoInput = nil
                self.pixelBufferAdaptor = nil

                let path = url.path
                // Save to Photos in the background
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }, completionHandler: { success, _ in
                    // Return file path regardless of Photo Library save result
                    DispatchQueue.main.async { result(path) }
                })
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension VideoMixerPlugin: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording, let aw = assetWriter else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if startTime == nil {
            startTime = pts
            aw.startWriting()
            aw.startSession(atSourceTime: pts)
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let isMain = (output == mainOutput)

        if isMain {
            queue.async { [weak self, pixelBuffer] in
                guard let self = self else { return }
                self.mainPixelBuffer = pixelBuffer
                self.compositeAndWrite(pts: pts)
            }
        } else {
            queue.async { [weak self, pixelBuffer] in
                guard let self = self else { return }
                self.pipPixelBuffer = pixelBuffer
            }
        }
    }

    private func compositeAndWrite(pts: CMTime) {
        guard let main = mainPixelBuffer else { return }
        guard let adaptor = pixelBufferAdaptor, let input = videoInput, input.isReadyForMoreMediaData else { return }
        guard let start = startTime else { return }
        guard let out = outputBuffer else { return }

        // Lock input and output buffers
        CVPixelBufferLockBaseAddress(main, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])

        let mainAddr = CVPixelBufferGetBaseAddress(main)!
        let outAddr = CVPixelBufferGetBaseAddress(out)!
        let mainW = CVPixelBufferGetWidth(main)
        let mainH = CVPixelBufferGetHeight(main)
        let mainRow = CVPixelBufferGetBytesPerRow(main)
        let outRow = outW * 4

        // Rotate main camera 90° CCW to fill portrait output
        var srcBuf = vImage_Buffer(data: mainAddr,
                                   height: vImagePixelCount(mainH),
                                   width: vImagePixelCount(mainW),
                                   rowBytes: mainRow)
        var dstBuf = vImage_Buffer(data: outAddr,
                                   height: vImagePixelCount(outH),
                                   width: vImagePixelCount(outW),
                                   rowBytes: outRow)

        var bgColor: UInt8 = 0
        let rotateErr = vImageRotate_ARGB8888(&srcBuf, &dstBuf, nil,
                                               Float.pi / 2, &bgColor,
                                               vImage_Flags(kvImageHighQualityResampling))
        if rotateErr != kvImageNoError {
            pixelTransposeBGRA(mainAddr, outAddr, mainW, mainH, mainRow, outRow)
        }

        CVPixelBufferUnlockBaseAddress(main, .readOnly)
        CVPixelBufferUnlockBaseAddress(out, [])

        // Send main camera preview (before PiP overlay)
        sendPreview(out)

        // Overlay PiP if available
        var pipTargetW = 0; var pipTargetH = 0
        if pipEnabled, let pip = pipPixelBuffer {
            pipTargetW = Int(pipNormW * CGFloat(outW))
            pipTargetH = Int(pipNormH * CGFloat(outH))
            let pipTargetX = Int(pipNormX * CGFloat(outW))
            let pipTargetY = Int(pipNormY * CGFloat(outH))

            let pX = max(0, min(pipTargetX, outW - pipTargetW))
            let pY = max(0, min(pipTargetY, outH - pipTargetH))
            let pW = min(pipTargetW, outW - pX)
            let pH = min(pipTargetH, outH - pY)

            let pipNeedsMirror = !useMainFront

            if pW > 0 && pH > 0 {
                overlayPip(pip, onto: out, atX: pX, y: pY, targetW: pW, targetH: pH, mirror: pipNeedsMirror)

                // Send PiP camera preview
                sendPipPreview(pip, srcW: pW, srcH: pH)
            }
        }

        // Overlay photos (multi-photo)
        for po in photoOverlays {
            let pW = Int(po.normW * CGFloat(outW))
            let pH = Int(po.normH * CGFloat(outH))
            let pX = Int(po.normX * CGFloat(outW))
            let pY = Int(po.normY * CGFloat(outH))
            let cx = max(0, min(pX, outW - pW))
            let cy = max(0, min(pY, outH - pH))
            let cw = min(pW, outW - cx)
            let ch = min(pH, outH - cy)
            if cw > 0 && ch > 0 {
                overlayPhoto(po.image, onto: out, atX: cx, atY: cy, targetW: cw, targetH: ch)
            }
        }

        // Write composited frame (main + PiP + photo) to asset writer
        let adjustedPts = CMTimeSubtract(pts, start)
        adaptor.append(out, withPresentationTime: adjustedPts)
    }

    /// Pixel-by-pixel transpose (90° CCW) fallback if vImageRotate fails
    private func pixelTransposeBGRA(_ src: UnsafeMutableRawPointer, _ dst: UnsafeMutableRawPointer,
                                    _ srcW: Int, _ srcH: Int, _ srcRow: Int, _ dstRow: Int) {
        DispatchQueue.concurrentPerform(iterations: srcW) { x in
            for y in 0..<srcH {
                let si = y * srcRow + x * 4
                let di = x * dstRow + (srcW - 1 - y) * 4
                dst.storeBytes(of: src.load(fromByteOffset: si, as: UInt8.self), toByteOffset: di, as: UInt8.self)
                dst.storeBytes(of: src.load(fromByteOffset: si + 1, as: UInt8.self), toByteOffset: di + 1, as: UInt8.self)
                dst.storeBytes(of: src.load(fromByteOffset: si + 2, as: UInt8.self), toByteOffset: di + 2, as: UInt8.self)
                dst.storeBytes(of: src.load(fromByteOffset: si + 3, as: UInt8.self), toByteOffset: di + 3, as: UInt8.self)
            }
        }
    }

    /// Overlay PiP onto composited output using vImage (affine transform + alpha blend)
    private func overlayPip(_ pip: CVPixelBuffer, onto out: CVPixelBuffer,
                            atX: Int, y: Int, targetW: Int, targetH: Int, mirror: Bool) {
        CVPixelBufferLockBaseAddress(pip, .readOnly)
        CVPixelBufferLockBaseAddress(out, .readOnly)

        let pipAddr = CVPixelBufferGetBaseAddress(pip)!
        let pipRow = CVPixelBufferGetBytesPerRow(pip)
        let outAddr = CVPixelBufferGetBaseAddress(out)!
        let outRow = CVPixelBufferGetBytesPerRow(out)

        // Scale PiP to target size
        let total = targetW * targetH * 4
        var scaled = Data(count: total)
        scaled.withUnsafeMutableBytes { dst in
            guard let dstPtr = dst.baseAddress else { return }
            var dstImg = vImage_Buffer(data: dstPtr,
                                       height: vImagePixelCount(targetH),
                                       width: vImagePixelCount(targetW),
                                       rowBytes: targetW * 4)
            var srcImg = vImage_Buffer(data: pipAddr,
                                       height: vImagePixelCount(CVPixelBufferGetHeight(pip)),
                                       width: vImagePixelCount(CVPixelBufferGetWidth(pip)),
                                       rowBytes: pipRow)
            vImageScale_ARGB8888(&srcImg, &dstImg, nil, vImage_Flags(kvImageNoFlags))
        }

        // Mirror horizontally if needed
        var scaledBuf = scaled
        if mirror {
            scaledBuf.withUnsafeMutableBytes { dst in
                guard let dstPtr = dst.baseAddress else { return }
                for row in 0..<targetH {
                    let rowBase = row * targetW * 4
                    for col in 0..<(targetW / 2) {
                        let a = rowBase + col * 4
                        let b = rowBase + (targetW - 1 - col) * 4
                        for c in 0..<4 {
                            let tmp = dstPtr.load(fromByteOffset: a + c, as: UInt8.self)
                            dstPtr.storeBytes(of: dstPtr.load(fromByteOffset: b + c, as: UInt8.self), toByteOffset: a + c, as: UInt8.self)
                            dstPtr.storeBytes(of: tmp, toByteOffset: b + c, as: UInt8.self)
                        }
                    }
                }
            }
        }

        // Alpha blend onto output
        scaledBuf.withUnsafeBytes { src in
            guard let srcPtr = src.baseAddress else { return }
            for row in 0..<targetH {
                let outBase = (y + row) * outRow + atX * 4
                let srcBase = row * targetW * 4
                for col in 0..<targetW {
                    let si = srcBase + col * 4
                    let di = outBase + col * 4
                    let sa = CGFloat(srcPtr.load(fromByteOffset: si + 3, as: UInt8.self)) / 255.0
                    for c in 0..<3 {
                        let s = CGFloat(srcPtr.load(fromByteOffset: si + c, as: UInt8.self))
                        let d = CGFloat(outAddr.load(fromByteOffset: di + c, as: UInt8.self))
                        let r = UInt8(s * sa + d * (1 - sa))
                        outAddr.storeBytes(of: r, toByteOffset: di + c, as: UInt8.self)
                    }
                }
            }
        }

        CVPixelBufferUnlockBaseAddress(pip, .readOnly)
        CVPixelBufferUnlockBaseAddress(out, .readOnly)
    }

    /// Overlay photo onto composited output (BoxFit.cover + rounded rect + shadow + zoom)
    private func overlayPhoto(_ image: CGImage, onto out: CVPixelBuffer,
                              atX: Int, atY: Int, targetW: Int, targetH: Int) {
        let imgW = image.width
        let imgH = image.height
        let scale = max(CGFloat(targetW) / CGFloat(imgW), CGFloat(targetH) / CGFloat(imgH))
        let sw = Int(CGFloat(targetW) / scale)
        let sh = Int(CGFloat(targetH) / scale)
        let sl = (imgW - sw) / 2
        let st = (imgH - sh) / 2

        // Crop to cover rect
        guard let cropped = image.cropping(to: CGRect(x: sl, y: st, width: sw, height: sh)) else { return }

        let cr = min(max(pipCornerRadius, 0), 30)
        let sa = min(max(CGFloat(pipShadowAlpha), 0), 255) / 255.0
        let zm = max(pipZoom, 1.0)
        let colorSpace = cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        // Create rendering context for photo at target size
        let ctx = CGContext(data: nil, width: targetW, height: targetH,
                            bitsPerComponent: 8, bytesPerRow: targetW * 4,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cgCtx = ctx else { return }
        cgCtx.interpolationQuality = .high

        let photoRect = CGRect(x: 0, y: 0, width: targetW, height: targetH)
        let clipPath = UIBezierPath(roundedRect: photoRect, cornerRadius: cr).cgPath

        // Draw shadow (rounded rect fill at offset with shadow color)
        if sa > 0 {
            cgCtx.saveGState()
            cgCtx.setShadow(offset: CGSize(width: pipShadowDx, height: pipShadowDy),
                            blur: pipShadowBlur,
                            color: UIColor.black.withAlphaComponent(sa).cgColor)
            cgCtx.addPath(clipPath)
            cgCtx.setFillColor(UIColor.black.cgColor)
            cgCtx.fillPath()
            cgCtx.restoreGState()
            // Clear the filled area, leaving only the shadow
            cgCtx.saveGState()
            cgCtx.addPath(clipPath)
            cgCtx.setBlendMode(.clear)
            cgCtx.fillPath()
            cgCtx.restoreGState()
        }

        // Draw image with rounded rect clip and optional zoom
        cgCtx.saveGState()
        cgCtx.addPath(clipPath)
        cgCtx.clip()
        if zm > 1.0001 {
            let zsw = Int(CGFloat(sw) / zm)
            let zsh = Int(CGFloat(sh) / zm)
            let zsl = sl + (sw - zsw) / 2
            let zst = st + (sh - zsh) / 2
            if let zoomed = image.cropping(to: CGRect(x: zsl, y: zst, width: zsw, height: zsh)) {
                cgCtx.draw(zoomed, in: photoRect)
            }
        } else {
            cgCtx.draw(cropped, in: photoRect)
        }
        cgCtx.restoreGState()

        guard let renderedData = cgCtx.data else { return }

        // Alpha blend onto output
        CVPixelBufferLockBaseAddress(out, .readOnly)
        let outAddr = CVPixelBufferGetBaseAddress(out)!
        let outRow = CVPixelBufferGetBytesPerRow(out)

        let src = renderedData.bindMemory(to: UInt8.self, capacity: targetW * targetH * 4)
        for row in 0..<targetH {
            let outBase = (atY + row) * outRow + atX * 4
            let srcBase = row * targetW * 4
            for col in 0..<targetW {
                let si = srcBase + col * 4
                let di = outBase + col * 4
                let alpha = CGFloat(src[si + 3]) / 255.0
                if alpha < 0.01 { continue }
                for c in 0..<3 {
                    let s = CGFloat(src[si + c])
                    let d = CGFloat(outAddr.load(fromByteOffset: di + c, as: UInt8.self))
                    let r = UInt8(s * alpha + d * (1 - alpha))
                    outAddr.storeBytes(of: r, toByteOffset: di + c, as: UInt8.self)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(out, .readOnly)
    }

    /// Send main camera preview via Flutter event channel
    private func sendPreview(_ buffer: CVPixelBuffer) {
        guard previewFrameCount % 3 == 0, previewSink != nil else { previewFrameCount += 1; return }
        previewFrameCount += 1

        let total = previewW * previewH * 4
        var rgba = Data(count: total)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let addr = CVPixelBufferGetBaseAddress(buffer)!
        let srcRow = CVPixelBufferGetBytesPerRow(buffer)

        rgba.withUnsafeMutableBytes { dst in
            guard let dstPtr = dst.baseAddress else { return }
            var dstImg = vImage_Buffer(data: dstPtr,
                                       height: vImagePixelCount(previewH),
                                       width: vImagePixelCount(previewW),
                                       rowBytes: previewW * 4)
            var srcImg = vImage_Buffer(data: addr,
                                       height: vImagePixelCount(outH),
                                       width: vImagePixelCount(outW),
                                       rowBytes: srcRow)
            let scaleErr = vImageScale_ARGB8888(&srcImg, &dstImg, nil, vImage_Flags(kvImageNoFlags))
            if scaleErr != kvImageNoError {
                // Fallback: nearest-neighbor downscale
                for py in 0..<previewH {
                    for px in 0..<previewW {
                        let sx = (px * outW) / previewW
                        let sy = (py * outH) / previewH
                        let si = sy * srcRow + sx * 4
                        let di = (py * previewW + px) * 4
                        dstPtr.storeBytes(of: addr.load(fromByteOffset: si + 2, as: UInt8.self), toByteOffset: di, as: UInt8.self)
                        dstPtr.storeBytes(of: addr.load(fromByteOffset: si + 1, as: UInt8.self), toByteOffset: di + 1, as: UInt8.self)
                        dstPtr.storeBytes(of: addr.load(fromByteOffset: si, as: UInt8.self), toByteOffset: di + 2, as: UInt8.self)
                        dstPtr.storeBytes(of: addr.load(fromByteOffset: si + 3, as: UInt8.self), toByteOffset: di + 3, as: UInt8.self)
                    }
                }
            } else {
                // Swap R and B (BGRA → RGBA)
                let d = dst.bindMemory(to: UInt8.self)
                for i in 0..<(total / 4) {
                    let base = i * 4
                    let tmp = d[base]
                    d[base] = d[base + 2]
                    d[base + 2] = tmp
                }
            }
        }

        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)

        self.previewSink?([
            "width": self.previewW,
            "height": self.previewH,
            "pixels": FlutterStandardTypedData(bytes: rgba)
        ])
    }

    /// Send PiP camera preview via Flutter event channel
    private func sendPipPreview(_ buffer: CVPixelBuffer, srcW: Int, srcH: Int) {
        guard pipPreviewSink != nil else { return }

        let pW = min(srcW, previewW)
        let pH = min(srcH, previewH)
        let total = pW * pH * 4
        var rgba = Data(count: total)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let addr = CVPixelBufferGetBaseAddress(buffer)!
        let srcRow = CVPixelBufferGetBytesPerRow(buffer)

        rgba.withUnsafeMutableBytes { dst in
            guard let dstPtr = dst.baseAddress else { return }
            var dstImg = vImage_Buffer(data: dstPtr,
                                       height: vImagePixelCount(pH),
                                       width: vImagePixelCount(pW),
                                       rowBytes: pW * 4)
            var srcImg = vImage_Buffer(data: addr,
                                       height: vImagePixelCount(srcH),
                                       width: vImagePixelCount(srcW),
                                       rowBytes: srcRow)

            let scaleErr = vImageScale_ARGB8888(&srcImg, &dstImg, nil, vImage_Flags(kvImageNoFlags))
            if scaleErr == kvImageNoError {
                let d = dst.bindMemory(to: UInt8.self)
                for i in 0..<(total / 4) {
                    let base = i * 4
                    let tmp = d[base]
                    d[base] = d[base + 2]
                    d[base + 2] = tmp
                }
            } else {
                let d = dst.bindMemory(to: UInt8.self)
                for py in 0..<pH {
                    for px in 0..<pW {
                        let sx = (px * srcW) / pW
                        let sy = (py * srcH) / pH
                        let si = sy * srcRow + sx * 4
                        let di = (py * pW + px) * 4
                        d[di] = addr.load(fromByteOffset: si + 2, as: UInt8.self)
                        d[di + 1] = addr.load(fromByteOffset: si + 1, as: UInt8.self)
                        d[di + 2] = addr.load(fromByteOffset: si, as: UInt8.self)
                        d[di + 3] = addr.load(fromByteOffset: si + 3, as: UInt8.self)
                    }
                }
            }
        }

        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)

        self.pipPreviewSink?([
            "width": pW,
            "height": pH,
            "pixels": FlutterStandardTypedData(bytes: rgba)
        ])
    }
}

// MARK: - PiP Preview Stream Handler

private class PipPreviewStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: VideoMixerPlugin?
    init(plugin: VideoMixerPlugin) { self.plugin = plugin; super.init() }
    func onListen(withArguments args: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.pipPreviewSink = events; return nil
    }
    func onCancel(withArguments args: Any?) -> FlutterError? {
        plugin?.pipPreviewSink = nil; return nil
    }
}

// MARK: - FlutterStreamHandler

extension VideoMixerPlugin: FlutterStreamHandler {
    func onListen(withArguments args: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        previewSink = events; return nil
    }
    func onCancel(withArguments args: Any?) -> FlutterError? {
        previewSink = nil; return nil
    }
}
