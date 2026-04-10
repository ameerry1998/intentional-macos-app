//
//  NudeNetDetector.swift
//  Intentional
//
//  On-device NSFW detection using NudeNet v3 CoreML model (YOLOv8n-based).
//  Uses Vision framework (VNCoreMLRequest) for preprocessing — handles
//  image resizing, normalization, and tensor layout automatically.
//

import Foundation
import CoreML
import CoreGraphics
import Vision

/// Write debug to file since NSLog is privacy-redacted on macOS 26
private func nudeNetLog(_ msg: String) {
    let path = "/tmp/intentional-csm-debug.log"
    if let data = msg.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path),
           let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            h.seekToEndOfFile(); h.write(data); h.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

class NudeNetDetector {

    // MARK: - Types

    struct Detection {
        let label: String
        let confidence: Float
        let boundingBox: CGRect
    }

    struct AnalysisResult {
        let isExplicit: Bool
        let isConfirmed: Bool
        let detections: [Detection]
        let topDetection: Detection?
    }

    // MARK: - Model Constants

    static let classLabels = [
        "FEMALE_GENITALIA_COVERED",   // 0
        "FACE_FEMALE",                // 1
        "BUTTOCKS_EXPOSED",           // 2
        "FEMALE_BREAST_EXPOSED",      // 3
        "FEMALE_GENITALIA_EXPOSED",   // 4
        "MALE_BREAST_EXPOSED",        // 5
        "ANUS_EXPOSED",               // 6
        "FEET_EXPOSED",               // 7
        "BELLY_COVERED",              // 8
        "FEET_COVERED",               // 9
        "ARMPITS_COVERED",            // 10
        "ARMPITS_EXPOSED",            // 11
        "FACE_MALE",                  // 12
        "BELLY_EXPOSED",              // 13
        "MALE_GENITALIA_EXPOSED",     // 14
        "ANUS_COVERED",               // 15
        "FEMALE_BREAST_COVERED",      // 16
        "BUTTOCKS_COVERED"            // 17
    ]

    private static let bboxOffset = 4

    // Critical: genitalia + anus exposed
    private static let criticalClassIndices: Set<Int> = [4, 14, 6]
    private static let criticalThreshold: Float = 0.70

    // Secondary: breast + buttocks exposed
    private static let secondaryClassIndices: Set<Int> = [3, 2]
    private static let secondaryThreshold: Float = 0.75

    private static let explicitClassIndices = criticalClassIndices.union(secondaryClassIndices)
    private static let nmsIoUThreshold: Float = 0.45

    // MARK: - Temporal Filter

    private var recentFrames: [Bool] = []
    private static let temporalWindowSize = 5
    private static let temporalConfirmThreshold = 3

    // MARK: - Vision Model

    private let vnModel: VNCoreMLModel

    // MARK: - Init

    init?() {
        guard let modelURL = Bundle.main.url(forResource: "NudeNetV3", withExtension: "mlmodelc")
                ?? Self.compileModelIfNeeded() else {
            nudeNetLog("[NudeNet] Model file not found in bundle\n")
            return nil
        }
        nudeNetLog("[NudeNet] Model URL: \(modelURL.path)\n")

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        do {
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            self.vnModel = try VNCoreMLModel(for: mlModel)
            let desc = mlModel.modelDescription
            let msg = "[NudeNet] Model loaded via Vision — inputs: [\(desc.inputDescriptionsByName.keys.joined(separator: ", "))], outputs: [\(desc.outputDescriptionsByName.keys.joined(separator: ", "))]\n"
            nudeNetLog(msg)
        } catch {
            let msg = "[NudeNet] FAILED to load: \(error.localizedDescription)\n"
            nudeNetLog(msg)
            return nil
        }
    }

    private static func compileModelIfNeeded() -> URL? {
        guard let packageURL = Bundle.main.url(forResource: "NudeNetV3", withExtension: "mlpackage") else {
            return nil
        }
        do {
            let compiledURL = try MLModel.compileModel(at: packageURL)
            NSLog("[NudeNet] Compiled model from .mlpackage")
            return compiledURL
        } catch {
            NSLog("[NudeNet] Failed to compile .mlpackage: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Public API

    func analyze(_ image: CGImage) -> AnalysisResult {
        let safeResult = AnalysisResult(isExplicit: false, isConfirmed: false, detections: [], topDetection: nil)

        // Run Vision request synchronously on a background queue to avoid main thread deadlock
        var resultDetections: [Detection] = []
        var visionError: Error? = nil

        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { semaphore.signal(); return }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let request = VNCoreMLRequest(model: self.vnModel) { request, error in
                if let error = error {
                    nudeNetLog("[NudeNet] Vision error: \(error.localizedDescription)\n")
                    return
                }

                guard let results = request.results as? [VNCoreMLFeatureValueObservation],
                      let first = results.first,
                      let outputArray = first.featureValue.multiArrayValue else {
                    nudeNetLog("[NudeNet] No feature value observations\n")
                    return
                }

                resultDetections = self.parseAndFilter(outputArray)
            }
            request.imageCropAndScaleOption = .scaleFill

            do {
                try handler.perform([request])
            } catch {
                visionError = error
            }

            semaphore.signal()
        }

        // Wait up to 5 seconds for the Vision request to complete
        let timeout = semaphore.wait(timeout: .now() + 5.0)
        if timeout == .timedOut {
            nudeNetLog("[NudeNet] Vision request TIMED OUT\n")
            recordFrame(explicit: false)
            return safeResult
        }

        if let error = visionError {
            nudeNetLog("[NudeNet] Handler error: \(error.localizedDescription)\n")
            recordFrame(explicit: false)
            return safeResult
        }

        let isExplicit = !resultDetections.isEmpty
        let topDetection = resultDetections.max(by: { $0.confidence < $1.confidence })

        recordFrame(explicit: isExplicit)
        let isConfirmed = checkTemporalConfirmation()

        if isExplicit {
            let labels = resultDetections.map { "\($0.label)(\(String(format: "%.2f", $0.confidence)))" }
            NSLog("[NudeNet] Explicit: \(labels.joined(separator: ", ")) | confirmed=\(isConfirmed)")
        }

        return AnalysisResult(
            isExplicit: isExplicit,
            isConfirmed: isConfirmed,
            detections: resultDetections,
            topDetection: topDetection
        )
    }

    func resetTemporalFilter() {
        recentFrames.removeAll()
    }

    // MARK: - Output Parsing

    private func parseAndFilter(_ output: MLMultiArray) -> [Detection] {
        let shape = output.shape.map { $0.intValue }
        guard shape.count >= 2 else { return [] }

        let numRows: Int
        let numCols: Int
        if shape.count == 3 {
            numRows = shape[1]
            numCols = shape[2]
        } else {
            numRows = shape[0]
            numCols = shape[1]
        }

        guard numRows >= 22 else { return [] }

        // Use safe subscript access with [NSNumber] indices instead of linear indexing
        let is3D = shape.count == 3
        let totalElements = output.count

        nudeNetLog("[NudeNet] parse: shape=\(shape) strides=\(output.strides) count=\(totalElements) dt=\(output.dataType.rawValue)\n")

        // Safe accessor function
        func safeRead(row: Int, col: Int) -> Float {
            if is3D {
                return output[[0, NSNumber(value: row), NSNumber(value: col)]].floatValue
            } else {
                return output[[NSNumber(value: row), NSNumber(value: col)]].floatValue
            }
        }

        // Debug: sample max scores
        var globalMaxScore: Float = 0
        var globalMaxLabel = ""
        for sampleC in Swift.stride(from: 0, to: min(numCols, 2100), by: 50) {
            for cls in 0..<18 {
                let score = safeRead(row: Self.bboxOffset + cls, col: sampleC)
                if score > globalMaxScore {
                    globalMaxScore = score
                    globalMaxLabel = Self.classLabels[cls]
                }
            }
        }

        let debugPath = "/tmp/intentional-csm-debug.log"
        let debugLine = "[NudeNet] shape=\(shape) strides=\(output.strides) maxScore=\(String(format: "%.4f", globalMaxScore)) maxLabel=\(globalMaxLabel) dt=\(output.dataType.rawValue)\n"
        if let data = debugLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: debugPath),
               let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: debugPath)) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: debugPath, contents: data)
            }
        }

        var detections: [Detection] = []

        for c in 0..<numCols {
            var bestClassIndex = -1
            var bestScore: Float = 0.0

            for cls in 0..<18 {
                let score = safeRead(row: Self.bboxOffset + cls, col: c)
                if score > bestScore {
                    bestScore = score
                    bestClassIndex = cls
                }
            }

            guard bestClassIndex >= 0 else { continue }

            let threshold: Float
            if Self.criticalClassIndices.contains(bestClassIndex) {
                threshold = Self.criticalThreshold
            } else if Self.secondaryClassIndices.contains(bestClassIndex) {
                threshold = Self.secondaryThreshold
            } else {
                continue
            }

            guard bestScore >= threshold else { continue }

            let cx = safeRead(row: 0, col: c)
            let cy = safeRead(row: 1, col: c)
            let w  = safeRead(row: 2, col: c)
            let h  = safeRead(row: 3, col: c)

            detections.append(Detection(
                label: Self.classLabels[bestClassIndex],
                confidence: bestScore,
                boundingBox: CGRect(x: CGFloat(cx - w/2), y: CGFloat(cy - h/2),
                                    width: CGFloat(w), height: CGFloat(h))
            ))
        }

        // NMS
        return nonMaxSuppression(detections)
    }

    // MARK: - NMS

    private func nonMaxSuppression(_ detections: [Detection]) -> [Detection] {
        guard !detections.isEmpty else { return [] }
        let sorted = detections.sorted { $0.confidence > $1.confidence }
        var kept: [Detection] = []
        var suppressed = [Bool](repeating: false, count: sorted.count)

        for i in 0..<sorted.count {
            guard !suppressed[i] else { continue }
            kept.append(sorted[i])
            for j in (i + 1)..<sorted.count {
                guard !suppressed[j] else { continue }
                if iou(sorted[i].boundingBox, sorted[j].boundingBox) > Self.nmsIoUThreshold {
                    suppressed[j] = true
                }
            }
        }
        return kept
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let iArea = Float(intersection.width * intersection.height)
        let uArea = Float(a.width * a.height) + Float(b.width * b.height) - iArea
        return uArea > 0 ? iArea / uArea : 0
    }

    // MARK: - Temporal Voting

    private func recordFrame(explicit: Bool) {
        recentFrames.append(explicit)
        if recentFrames.count > Self.temporalWindowSize {
            recentFrames.removeFirst()
        }
    }

    private func checkTemporalConfirmation() -> Bool {
        recentFrames.filter { $0 }.count >= Self.temporalConfirmThreshold
    }
}
