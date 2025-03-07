//
//  ContentView.swift
//  jomiage
//
//  Created by aimer on 2025/03/06.
//

import AVFoundation
import SwiftUI
import Vision

import ScreenCaptureKit

class ScreenRecorder: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let captureRect: CGRect
    private let scaleFactor: CGFloat

    private var texts: [String] = .init()

    init(captureRect: CGRect, scaleFactor: CGFloat = 1.0) {
        self.captureRect = captureRect
        self.scaleFactor = scaleFactor
    }

    func startCapture() async {
//        startRecording()

        do {
            // スクリーンの取得（デフォルトのメインディスプレイ）
            guard let display = try await SCShareableContent.current.displays.first else {
                print("Error: No display found")
                return
            }

            // キャプチャ設定
            let config = SCStreamConfiguration()
            config.minimumFrameInterval = CMTime(value: 1, timescale: 3) // 3FPS
            config.queueDepth = 6 // バッファ保持数

            // ストリーム開始
            stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.global())

            try await stream?.startCapture()

            print("Screen capture started")

        } catch {
            print("Error starting capture: \(error)")
        }
    }

    func stopCapture() {
        stream?.stopCapture()
        stream = nil
        print("Screen capture stopped")
    }

    // SCStreamOutput プロトコルの実装（画像データを取得）
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)

        // captureRectでスクリーンショットをクロップする
        let cropped = ciImage.cropped(to: captureRect)

        // 画像の白黒を反転
        let invertedImage = cropped.applyingFilter("CIColorInvert")

        // OCR処理を実行
        let context = CIContext()
        if let cgImage = context.createCGImage(invertedImage, from: invertedImage.extent) {
            recognizeText(from: cgImage)
        }
    }

    var beforeComment: String = ""

    func recognizeText(from image: CGImage) {
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            for observation in observations {
                if let topCandidate = observation.topCandidates(1).first {
//                    print("Recognized Text: \(topCandidate.string)")

                    let comment = topCandidate.string

                    // 信頼度が低すぎる場合無視する
                    if topCandidate.confidence < 0.5 {
                        continue
                    }

                    // 多重重複チェック
                    if self.texts.contains(comment) {
                        continue
                    }

                    // ignore list
                    if comment == "｛" {
                        continue
                    }

                    // 短すぎると読まない
                    if comment.count < 2 {
                        continue
                    }

                    // 相互包含
                    if true {
                        if comment.contains(self.beforeComment) {
                            continue
                        }

                        if self.beforeComment.contains(comment) {
                            continue
                        }
                    }

                    if self.hasCommonCharacters(over: 60, str1: self.beforeComment, str2: comment) {
                        print("重複排除")
                        continue
                    }

                    self.beforeComment = comment

                    let hiraganaComment = self.convertToHiragana(comment)
                    self.texts.append(hiraganaComment)

                    // 発声する
                    print("comment", comment, "hiraganaComment", hiraganaComment, "confidence", topCandidate.confidence)
                    self.synthesizeSpeech(from: topCandidate.string)
                }
            }
        }
        request.recognitionLanguages = ["ja-JP"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
    }

    func hasCommonCharacters(over threshold: Double, str1: String, str2: String) -> Bool {
        let set1 = Set(str1)
        let set2 = Set(str2)

        let commonCount = set1.intersection(set2).count
        let totalCount = max(set1.count, set2.count) // 大きい方の文字数を基準に割合計算

        let commonRatio = Double(commonCount) / Double(totalCount)
        print("commonRatio", commonRatio)
        return commonRatio >= threshold / 100.0
    }

    func convertToHiragana(_ text: String) -> String {
        let locale = CFLocaleCreate(kCFAllocatorDefault, CFLocaleIdentifier("ja_JP" as CFString))
        let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault, text as CFString, CFRangeMake(0, text.utf16.count), kCFStringTokenizerUnitWord, locale)

        var result = ""

        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            if let reading = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) {
                result += reading as! String
            } else {
                result += text
            }
        }

        return result
    }

    func isSimilarText(_ text1: String, _ text2: String) -> Bool {
        let minLength = min(text1.count, text2.count)
        let commonPrefix = text1.commonPrefix(with: text2)

        return commonPrefix.count >= minLength - 1 // 1文字の違いまで許容
    }

    func startRecording() {
        do {
            let audioInput = audioEngine.inputNode
            let format = audioInput.outputFormat(forBus: 0)

            audioFile = try AVAudioFile(forWriting: audioFilename, settings: format.settings)

            audioInput.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                do {
                    try self.audioFile?.write(from: buffer)
                } catch {
                    print("Error writing audio buffer: \(error)")
                }
            }

            try audioEngine.start()
            isRecording = true
            print("Recording started path", path)
        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    /// 🛑 録音を停止 & MP3変換
    func stopRecording() {
//        audioEngine.stop()
//        audioEngine.inputNode.removeTap(onBus: 0)
//        isRecording = false
//        print("Recording stopped")
    }

    let synthesizer = AVSpeechSynthesizer()

    // 🔹 録音用
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var isRecording = false
    private let path = FileManager.default.temporaryDirectory
    private let audioFilename = FileManager.default.temporaryDirectory.appendingPathComponent("recorded_audio.wav")

    func synthesizeSpeech(from text: String) {
//        print("text", text)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")

        let voice = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "ja-JP" }
        for (i, v) in voice.enumerated() {
            if i == 7 {
                utterance.voice = v
                // 音を鳴らす
            }
        }

        // ここで、音を鳴らし、録音する。
        synthesizer.speak(utterance)
    }
}

struct ContentView: View {
    var body: some View {
        VStack {
            Button("start") {
                startCapture()
            }

            Button("stop") {
                stopCapture()
            }
        }
        .padding()
    }

    @State private var screenRecorder: ScreenRecorder!

    // 画面の特定の範囲をキャプチャ開始
    func startCapture() {
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 200)

        screenRecorder = ScreenRecorder(captureRect: rect)

        Task {
            await screenRecorder.startCapture()
        }
    }

    func stopCapture() {
        screenRecorder.stopRecording()
    }
}

#Preview {
    ContentView()
}
