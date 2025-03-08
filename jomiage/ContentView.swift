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
    private(set) var sampleImage: CGImage?

    // スクリーンショット機構
    private var stream: SCStream?
    private let captureRect: CGRect
    private let scaleFactor: CGFloat

    // 重複排除記録保持用
    #warning("無限に伸びていくのでいつか不味い")
    private var texts: [String] = .init()

    // 直前の文字列との比較用
    private var beforeComment: String = ""

    // 発声機構
    private let synthesizer = AVSpeechSynthesizer()

    // 録音機構
    #warning("まだunused")
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var isRecording = false
    private let path = FileManager.default.temporaryDirectory
    private let audioFilename = FileManager.default.temporaryDirectory.appendingPathComponent("recorded_audio.wav")

    // 初期化
    init(captureRect: CGRect, scaleFactor: CGFloat = 1.0) {
        self.captureRect = captureRect
        self.scaleFactor = scaleFactor
    }

    func startCapture() async {
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

    func skipQueuedComment() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    #warning("unused まだ使われてない")
    func stopCapture() {
        stream?.stopCapture()
        stream = nil
        print("Screen capture stopped")
    }

    // スクリーンショットで流れてきた画像を文字起こしし、発声処理に放り込む。
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)

        // captureRectでスクリーンショットをクロップする
        let cropped = ciImage.cropped(to: captureRect)

        // 識字のために画像の白黒を反転
        // TODO: オプションにしたほうがいいかもしれない
        let invertedImage = cropped.applyingFilter("CIColorInvert")

        // OCR処理を実行
        let context = CIContext()
        if let cgImage = context.createCGImage(invertedImage, from: invertedImage.extent) {
            sampleImage = cgImage
            recognizeText(from: cgImage)
        }
    }

    // 文字起こし→発声を行う。
    // 事前に発声済み、通過済み、文字起こしの揺れについて対処を行い、
    func recognizeText(from image: CGImage) {
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            for observation in observations {
                if let topCandidate = observation.topCandidates(1).first {
//                    print("Recognized Text: \(topCandidate.string)")

                    let comment = topCandidate.string

                    // 重複排除などを行う

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

                    // 重複割合による重複排除
                    if self.hasCommonCharacters(over: 60, str1: self.beforeComment, str2: comment) {
                        continue
                    }

                    // 鳴らすのが確定

                    // 直前のコメントを記録
                    self.beforeComment = comment

                    // 文字を全てアルファベットに変換し、読みを調整する
                    #warning("ログ以外に利用していない。")
                    let hiraganaComment = self.convertToHiragana(comment)

                    // 読み上げ確定なので、読み上げた記録に追加する。
                    self.texts.append(comment)

                    // 発声する
                    print("comment", comment, "hiraganaComment", hiraganaComment, "confidence", topCandidate.confidence)
                    self.speechComment(from: comment)
                }
            }
        }
        request.recognitionLanguages = ["ja-JP"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
    }

    // 前後のコメントを重複率で比較し、特定の割合以上に一致していればtrueを返す。
    func hasCommonCharacters(over threshold: Double, str1: String, str2: String) -> Bool {
        let set1 = Set(str1)
        let set2 = Set(str2)

        let commonCount = set1.intersection(set2).count
        let totalCount = max(set1.count, set2.count) // 大きい方の文字数を基準に割合計算

        let commonRatio = Double(commonCount) / Double(totalCount)

        // print("commonRatio", commonRatio)
        return commonRatio >= threshold / 100.0
    }

    // 文字列をアルファベットにする
    #warning("unusedなアルファベット化。読みを改善するために使いたい。")
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

    // 録音を開始する
    #warning("unused")
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

    // 録音を停止
    #warning("unused")
    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        print("Recording stopped")
    }

    // 日本語で発声する
    func speechComment(from text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")

        let voice = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "ja-JP" }
        for (i, v) in voice.enumerated() {
            #warning("適当に選んだ声")
            if i == 7 {
                utterance.voice = v
            }
        }

        // ここで、音を鳴らす。
        // この処理は自動的に発生すべき音声をキューイングし、たまった音声を順に発声する。
        synthesizer.speak(utterance)
    }
}

// メインUI
struct ContentView: View {
    var body: some View {
        VStack {
            Button("start") {
                startCapture()
            }.disabled(screenRecorder != nil)

            Button("skip") {
                skipCaptured()
            }.disabled(screenRecorder == nil)

            Button("Read Sample") {
                readSample()
            }.disabled(screenRecorder == nil)

            if let sample = sampleImage {
                Image(decorative: sample, scale: 1.0, orientation: .up)
                    .resizable()
                    .frame(width: 1000, height: 200) // 表示サイズを指定
                    .border(Color.gray, width: 1)
            } else {
                Text("No image available")
                    .foregroundColor(.gray)
            }
        }
        .padding()
    }

    // スクリーンショット→識字→発声を行うユニット
    @State private var screenRecorder: ScreenRecorder?

    // 画像
    @State private var sampleImage: CGImage?

    // 画面の特定の範囲をキャプチャ開始
    func startCapture() {
        #warning("キャプチャ範囲は脅威の直値固定で、ディスプレイの左下 1000 x 200 px")
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 200)

        let _screenRecorder = ScreenRecorder(captureRect: rect)

        screenRecorder = _screenRecorder

        Task {
            await _screenRecorder.startCapture()
        }
    }

    func skipCaptured() {
        guard let screenRecorder = screenRecorder else {
            fatalError("nilになっている")
        }

        // キューしている要素をスキップする
        screenRecorder.skipQueuedComment()
    }

    func readSample() {
        guard let screenRecorder = screenRecorder else {
            fatalError("nilになっている")
        }

        guard let sample = screenRecorder.sampleImage else {
            return
        }

        sampleImage = sample // 取得した CGImage を SwiftUI の State に格納
    }
}

#Preview {
    ContentView()
}
