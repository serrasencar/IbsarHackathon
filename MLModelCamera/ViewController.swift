import UIKit
import CoreML
import Vision
import AVFoundation
import Speech

class ViewController: UIViewController {
    
    // MARK: - Properties
    private var videoCapture: VideoCapture!
    private var latestCapturedImageData: Data?

    private let serialQueue = DispatchQueue(label: "com.shu223.coremlplayground.serialqueue")
    
    private let videoSize = CGSize(width: 1280, height: 720)
    private let preferredFps: Int32 = 2
    
    private var modelUrls: [URL]!
    private var selectedVNModel: VNCoreMLModel?
    private var selectedModel: MLModel?
    
    private var lastAPICallTime: CFTimeInterval = 0
    private let apiCallInterval: CFTimeInterval = 30.0
    private let apiKey = "fmFrMl3wHnB9SFnb8bzxNFpGCVE18Wcz"
    private let apiBaseURL = "https://api.fanar.qa/v1"
    
    // Speech synthesis and recognition
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // Add these properties to your ViewController class
    private var audioPlayer: AVAudioPlayer?
    private let ttsQueue = DispatchQueue(label: "com.shu223.tts.queue")
    
    // Vibration
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
    
    private var cropAndScaleOption: VNImageCropAndScaleOption = .scaleFit
    
    @IBOutlet weak var microphoneButton: UIButton!
    @IBOutlet weak var pause: UIButton!
    @IBOutlet private weak var previewView: UIView!
    @IBOutlet private weak var modelLabel: UILabel!
    @IBOutlet private weak var resultView: UIView!
    @IBOutlet private weak var resultLabel: UILabel!
    @IBOutlet private weak var othersLabel: UILabel!
    @IBOutlet private weak var bbView: BoundingBoxView!
    @IBOutlet weak var cropAndScaleOptionSelector: UISegmentedControl!
    
    // MARK: - View Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.bringSubviewToFront(microphoneButton)

        
        configureAudioSession()
        setupSpeechRecognition()
        
        let spec = VideoSpec(fps: preferredFps, size: videoSize)
        let frameInterval = 1.0 / Double(preferredFps)
        
        videoCapture = VideoCapture(cameraType: .back,
                                    preferredSpec: spec,
                                    previewContainer: previewView.layer)
        videoCapture.imageBufferHandler = {[unowned self] (imageBuffer, timestamp, outputBuffer) in
            let delay = CACurrentMediaTime() - timestamp.seconds
            if delay > frameInterval {
                return
            }

            self.serialQueue.async {
                self.runModel(imageBuffer: imageBuffer, timestamp: timestamp)
            }
        }
        
        let modelPaths = Bundle.main.paths(forResourcesOfType: "mlmodel", inDirectory: "models")
        
        modelUrls = []
        for modelPath in modelPaths {
            let url = URL(fileURLWithPath: modelPath)
            let compiledUrl = try! MLModel.compileModel(at: url)
            modelUrls.append(compiledUrl)
        }
        
        print("📦 Found \(modelUrls.count) models:")
        for (index, url) in modelUrls.enumerated() {
            print("   \(index + 1). \(url.modelName)")
        }
        
        if let firstModel = modelUrls.first {
            selectModel(url: firstModel)
        }
        
        cropAndScaleOptionSelector.selectedSegmentIndex = 2
        updateCropAndScaleOption()
        
        // Setup microphone button long press gesture
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleMicrophoneLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        microphoneButton.addGestureRecognizer(longPress)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let videoCapture = videoCapture else {return}
        videoCapture.startCapture()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let videoCapture = videoCapture else {return}
        videoCapture.resizePreview()
        self.bbView.updateSize(for: CGSize(width: videoSize.height, height: videoSize.width))
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        guard let videoCapture = videoCapture else {return}
        videoCapture.stopCapture()
        super.viewWillDisappear(animated)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    
    // MARK: - Speech Recognition
    private func setupSpeechRecognition() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    print("Speech recognition authorized")
                case .denied:
                    print("User denied access to speech recognition")
                case .restricted:
                    print("Speech recognition restricted on this device")
                case .notDetermined:
                    print("Speech recognition not yet authorized")
                @unknown default:
                    fatalError()
                }
            }
        }
    }
    
    @objc private func handleMicrophoneLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            microphoneButton.isHighlighted = true
            startListening()
        case .ended, .cancelled, .failed:
            microphoneButton.isHighlighted = false
            stopListening()
        default:
            break
        }
    }
    
    private func startListening() {
        // Stop any current speech
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        
        // Configure audio session for recording
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Audio session setup error: \(error)")
            return
        }
        
        // Cancel any existing recognition task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Setup audio engine
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        
        // Prepare recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            fatalError("Unable to create recognition request")
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let transcript = result.bestTranscription.formattedString
                print("User said: \(transcript)")
                
                // If this is the final result, send to API
                if result.isFinal {
                    self.sendVoicePromptToAPI(transcript: transcript, imageData: self.latestCapturedImageData)
                }
            }
            
            if error != nil {
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                self.recognitionTask = nil
            }
        }
        
        // Start audio engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
            print("Listening...")
        } catch {
            print("Audio engine start error: \(error)")
        }
    }

    private func stopListening() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // Restore audio session for playback
        configureAudioSession()
    }
    
    private func sendVoicePromptToAPI(transcript: String, imageData: Data? = nil) {
        print("Sending voice prompt to API: \(transcript)")
        
        // Validate transcript
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("❌ Empty transcript, not sending to API")
            speakText("I didn't catch that, please try again.")
            return
        }
        
        // Build the message content
        var messageContent: [[String: Any]] = [
            [
                "type": "text",
                "text": transcript
            ]
        ]
        
        // If image data is provided, attach as base64
        if let imageData = imageData {
            let imageBase64 = imageData.base64EncodedString()
            let imageB64Url = "data:image/jpeg;base64,\(imageBase64)"
            
            messageContent.append([
                "type": "image_url",
                "image_url": [
                    "url": imageB64Url
                ]
            ])
        }
        
        let llmRequest: [String: Any] = [
            "model": "Fanar-Oryx-IVU-1",
            "messages": [
                [
                    "role": "system",
                    "content": "You are an advanced navigation assistant for visually impaired users. Respond to the user's query with precise, actionable guidance. Keep responses under 30 words."
                ],
                [
                    "role": "user",
                    "content": messageContent
                ]
            ],
            "temperature": 0.2,
            "max_tokens": 100
        ]
        
        performVoiceAPICall(requestData: llmRequest)
    }



    private func performVoiceAPICall(requestData: [String: Any]) {
        guard let url = URL(string: "\(apiBaseURL)/chat/completions") else {
            print("❌ Invalid API URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestData)
            print("📤 Voice request payload size: \(request.httpBody?.count ?? 0) bytes")
            
            // Log the actual request being sent
            if let debugData = try? JSONSerialization.data(withJSONObject: requestData, options: .prettyPrinted),
               let debugString = String(data: debugData, encoding: .utf8) {
                print("📋 Voice request: \(debugString)")
            }
            
        } catch {
            print("❌ Failed to serialize voice request data: \(error)")
            speakText("Voice processing error, please try again.")
            return
        }
        
        print("📤 Sending Voice API request...")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("❌ Voice API call failed: \(error)")
                self?.speakText("Voice service temporarily unavailable.")
                return
            }
            
            guard let data = data else {
                print("❌ No data received from voice API")
                self?.speakText("No response received, please try again.")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 Voice API Response Status: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode != 200 {
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("❌ Voice API Error Response: \(responseString)")
                    }
                    
                    switch httpResponse.statusCode {
                    case 400:
                        print("❌ Bad Request - Invalid voice request format")
                    case 401:
                        print("❌ Unauthorized - Check API key")
                    case 500:
                        print("❌ Internal server error on voice request")
                    default:
                        break
                    }
                    
                    self?.speakText("Voice processing error, please try again.")
                    return
                }
            }
            
            do {
                if let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("📥 Voice API Response received")
                    
                    if let choices = jsonResponse["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        
                        let cleanedContent = content
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "  ", with: " ")
                        
                        print("🗣️ Voice Response: \(cleanedContent)")
                        self?.speakText(cleanedContent)
                        
                    } else {
                        print("❌ Unexpected voice response format")
                        if let debugData = try? JSONSerialization.data(withJSONObject: jsonResponse, options: .prettyPrinted),
                           let debugString = String(data: debugData, encoding: .utf8) {
                            print("Full response: \(debugString)")
                        }
                        self?.speakText("Response received but couldn't understand format.")
                    }
                }
            } catch {
                print("❌ Failed to parse voice API response: \(error)")
                if let responseString = String(data: data, encoding: .utf8) {
                    print("Raw voice response: \(responseString)")
                }
                self?.speakText("Voice processing complete.")
            }
        }.resume()
    }
    // MARK: - Model Selection
    private func showActionSheet() {
        let alert = UIAlertController(title: "Models", message: "Choose a model", preferredStyle: .actionSheet)
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alert.addAction(cancelAction)
        
        for modelUrl in modelUrls {
            let action = UIAlertAction(title: modelUrl.modelName, style: .default) { (action) in
                self.selectModel(url: modelUrl)
            }
            alert.addAction(action)
        }
        present(alert, animated: true, completion: nil)
    }
    
    private func selectModel(url: URL) {
        selectedModel = try! MLModel(contentsOf: url)
        do {
            selectedVNModel = try VNCoreMLModel(for: selectedModel!)
            modelLabel.text = url.modelName
            print("✅ Model selected: \(url.modelName)")
        }
        catch {
            print("❌ Could not create VNCoreMLModel instance from \(url). error: \(error).")
            fatalError("Could not create VNCoreMLModel instance from \(url). error: \(error).")
        }
    }
    
    // MARK: - Model Processing
    private func runModel(imageBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let model = selectedVNModel else {
            print("❌ No model selected")
            return
        }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: imageBuffer)
        
        let request = VNCoreMLRequest(model: model, completionHandler: { (request, error) in
            if let error = error {
                print("❌ Model inference error: \(error)")
                return
            }
            
            if #available(iOS 12.0, *), let results = request.results as? [VNRecognizedObjectObservation] {
                print("🎯 OBJECT DETECTION RESULTS - Model: \(self.modelLabel.text ?? "Unknown")")
                self.processObjectDetectionObservations(results, imageBuffer: imageBuffer, timestamp: timestamp)
            }
        })
        
        request.preferBackgroundProcessing = true
        request.imageCropAndScaleOption = cropAndScaleOption
        
        do {
            try handler.perform([request])
        } catch {
            print("❌ Failed to perform model inference: \(error)")
        }
    }
    
    @available(iOS 12.0, *)
    private func processObjectDetectionObservations(_ results: [VNRecognizedObjectObservation], imageBuffer: CVPixelBuffer, timestamp: CMTime) {
        print("🎯 Detected \(results.count) objects:")
        
        var detectionData: [[String: Any]] = []
        var criticalObstacles: [String] = []
        var pathBlockers: [String] = []
        var environmentalHazards: [String] = []
        
        for (index, result) in results.enumerated() {
            let boundingBox = result.boundingBox
            
            let imageWidth = CVPixelBufferGetWidth(imageBuffer)
            let imageHeight = CVPixelBufferGetHeight(imageBuffer)
            let screenX = boundingBox.origin.x * CGFloat(imageWidth)
            let screenY = boundingBox.origin.y * CGFloat(imageHeight)
            let screenWidth = boundingBox.size.width * CGFloat(imageWidth)
            let screenHeight = boundingBox.size.height * CGFloat(imageHeight)
            
            let (horizontalPos, verticalPos, distance, urgency) = analyzeObjectPosition(boundingBox: boundingBox)
            
            // Trigger vibration for high urgency OR very close objects
            if urgency == "HIGH - directly in path" || distance == "very close" {
                DispatchQueue.main.async {
                    self.feedbackGenerator.impactOccurred()
                }
            }

            
            print("\n🔸 Object \(index + 1):")
            print("   📍 Position: \(horizontalPos), \(verticalPos)")
            print("   📏 Distance: \(distance)")
            print("   ⚠️ Urgency: \(urgency)")
            
            var labels: [[String: Any]] = []
            var topLabel = "unknown"
            var topConfidence: Float = 0
            
            for (labelIndex, label) in result.labels.enumerated() {
                let confidence = label.confidence * 100
                print("      \(labelIndex + 1). \(label.identifier) - \(String(format: "%.1f", confidence))%")
                
                if labelIndex == 0 {
                    topLabel = label.identifier
                    topConfidence = confidence
                }
                
                labels.append([
                    "class": label.identifier,
                    "confidence": confidence
                ])
            }
            
            let obstacleInfo = "\(topLabel) at \(horizontalPos) (\(distance))"
            
            if isMovingVehicle(topLabel) || isDangerousObject(topLabel) {
                criticalObstacles.append("🚨 \(obstacleInfo) - IMMEDIATE DANGER")
            } else if isPathBlocker(topLabel) {
                pathBlockers.append("🚧 \(obstacleInfo) - PATH BLOCKED")
            } else if isEnvironmentalHazard(topLabel) {
                environmentalHazards.append("⚠️ \(obstacleInfo) - CAUTION NEEDED")
            }
            
            let objectData: [String: Any] = [
                "id": index,
                "type": "detection",
                "boundingBox": [
                    "normalized": [
                        "x": boundingBox.origin.x,
                        "y": boundingBox.origin.y,
                        "width": boundingBox.size.width,
                        "height": boundingBox.size.height
                    ],
                    "pixels": [
                        "x": Int(screenX),
                        "y": Int(screenY),
                        "width": Int(screenWidth),
                        "height": Int(screenHeight)
                    ]
                ],
                "labels": labels,
                "topLabel": topLabel,
                "topConfidence": topConfidence,
                "position": [
                    "horizontal": horizontalPos,
                    "vertical": verticalPos,
                    "distance": distance,
                    "urgency": urgency
                ],
                "category": categorizeObject(topLabel)
            ]
            
            detectionData.append(objectData)
        }
        
        let currentTime = CACurrentMediaTime()
        if currentTime - lastAPICallTime >= apiCallInterval {
            lastAPICallTime = currentTime
            
            print("\n🚀 SENDING TO VISION-LANGUAGE API:")
            print("📊 Detection Data Count: \(detectionData.count) objects")
            print("🚨 Critical Obstacles: \(criticalObstacles.count)")
            print("🚧 Path Blockers: \(pathBlockers.count)")
            print("⚠️ Environmental Hazards: \(environmentalHazards.count)")
            
            let imageData = convertPixelBufferToImageData(imageBuffer)
            self.latestCapturedImageData = imageData  // ✅ Save for other use (like voice prompt)
            sendToVisionLanguageAPI(
                detectionData: detectionData,
                imageData: imageData,
                timestamp: timestamp.seconds,
                criticalObstacles: criticalObstacles,
                pathBlockers: pathBlockers,
                environmentalHazards: environmentalHazards
            )
        }
        
        bbView.observations = results
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.resultView.isHidden = true
            self.bbView.isHidden = false
            self.bbView.setNeedsDisplay()
        }
    }
    
    // MARK: - Object Analysis
    private func analyzeObjectPosition(boundingBox: CGRect) -> (horizontal: String, vertical: String, distance: String, urgency: String) {
        let x = boundingBox.origin.x
        let y = boundingBox.origin.y
        let width = boundingBox.size.width
        let height = boundingBox.size.height
        let area = width * height
        
        let horizontalPos: String
        if x < 0.15 {
            horizontalPos = "far left side"
        } else if x < 0.35 {
            horizontalPos = "left side"
        } else if x < 0.45 {
            horizontalPos = "slightly left of center"
        } else if x < 0.55 {
            horizontalPos = "directly ahead"
        } else if x < 0.65 {
            horizontalPos = "slightly right of center"
        } else if x < 0.85 {
            horizontalPos = "right side"
        } else {
            horizontalPos = "far right side"
        }
        
        let verticalPos: String
        if y < 0.2 {
            verticalPos = "ground level"
        } else if y < 0.5 {
            verticalPos = "waist height"
        } else if y < 0.8 {
            verticalPos = "eye level"
        } else {
            verticalPos = "overhead"
        }
        
        let distance: String
        if area > 0.3 {
            distance = "very close"
        } else if area > 0.15 {
            distance = "close"
        } else if area > 0.05 {
            distance = "medium distance"
        } else {
            distance = "far away"
        }
        
        let urgency: String
        if area > 0.2 && x > 0.3 && x < 0.7 && y < 0.5 {
            urgency = "HIGH - directly in path"
        } else if area > 0.1 && y < 0.3 {
            urgency = "MEDIUM - potential obstacle"
        } else {
            urgency = "LOW - not immediate concern"
        }
        
        return (horizontalPos, verticalPos, distance, urgency)
    }
    
    private func isMovingVehicle(_ label: String) -> Bool {
        let movingVehicles = ["car", "truck", "bus", "motorcycle", "bicycle", "scooter", "van", "taxi"]
        return movingVehicles.contains { label.lowercased().contains($0) }
    }
    
    private func isDangerousObject(_ label: String) -> Bool {
        let dangerous = ["person walking", "dog", "construction", "traffic", "barrier"]
        return dangerous.contains { label.lowercased().contains($0) }
    }
    
    private func isPathBlocker(_ label: String) -> Bool {
        let pathBlockers = ["chair", "table", "bench", "trash can", "pole", "tree", "fence", "sign", "hydrant", "barrier", "cone"]
        return pathBlockers.contains { label.lowercased().contains($0) }
    }
    
    private func isEnvironmentalHazard(_ label: String) -> Bool {
        let hazards = ["wet floor", "stairs", "step", "curb", "hole", "construction", "caution"]
        return hazards.contains { label.lowercased().contains($0) }
    }
    
    private func categorizeObject(_ label: String) -> String {
        if isMovingVehicle(label) { return "MOVING_VEHICLE" }
        if isDangerousObject(label) { return "DANGER" }
        if isPathBlocker(label) { return "PATH_BLOCKER" }
        if isEnvironmentalHazard(label) { return "ENVIRONMENTAL_HAZARD" }
        return "GENERAL_OBJECT"
    }
    
    // MARK: - API Integration
    private func sendToVisionLanguageAPI(
        detectionData: [[String: Any]],
        imageData: Data?,
        timestamp: Double,
        criticalObstacles: [String],
        pathBlockers: [String],
        environmentalHazards: [String]
    ) {
        print("🔄 Preparing Vision-Language API call...")
        
        let prompt = createEnhancedNavigationPrompt(
            detectionData: detectionData,
            criticalObstacles: criticalObstacles,
            pathBlockers: pathBlockers,
            environmentalHazards: environmentalHazards
        )
        
        var messageContent: [[String: Any]] = [
            [
                "type": "text",
                "text": prompt
            ]
        ]
        
        if let imageData = imageData {
            let imageBase64 = imageData.base64EncodedString()
            let imageB64Url = "data:image/jpeg;base64,\(imageBase64)"
            
            messageContent.append([
                "type": "image_url",
                "image_url": [
                    "url": imageB64Url
                ]
            ])
        }
        
        let llmRequest: [String: Any] = [
            "model": "Fanar-Oryx-IVU-1",
            "messages": [
                [
                    "role": "system",
                    "content": "You are an advanced navigation assistant for visually impaired users. Analyze both the object detection data AND the actual image to provide precise, actionable navigation guidance. Be specific about obstacles, their exact locations, and safe navigation paths. Keep responses under 30 words but be very specific about what obstacles exist and where."
                ],
                [
                    "role": "user",
                    "content": messageContent
                ]
            ],
            "temperature": 0.2,
            "max_tokens": 100
        ]
        
        performVisionLanguageAPICall(requestData: llmRequest)
    }
    
    private func createEnhancedNavigationPrompt(
        detectionData: [[String: Any]],
        criticalObstacles: [String],
        pathBlockers: [String],
        environmentalHazards: [String]
    ) -> String {
        var prompt = "NAVIGATION ANALYSIS FOR VISUALLY IMPAIRED USER\n\n"
        
        prompt += "OBJECT DETECTION SUMMARY:\n"
        
        if !criticalObstacles.isEmpty {
            prompt += "🚨 CRITICAL DANGERS:\n"
            for obstacle in criticalObstacles {
                prompt += "- \(obstacle)\n"
            }
        }
        
        if !pathBlockers.isEmpty {
            prompt += "\n🚧 PATH OBSTACLES:\n"
            for blocker in pathBlockers {
                prompt += "- \(blocker)\n"
            }
        }
        
        if !environmentalHazards.isEmpty {
            prompt += "\n⚠️ ENVIRONMENTAL HAZARDS:\n"
            for hazard in environmentalHazards {
                prompt += "- \(hazard)\n"
            }
        }
        
        if criticalObstacles.isEmpty && pathBlockers.isEmpty && environmentalHazards.isEmpty {
            prompt += "✅ NO MAJOR OBSTACLES DETECTED\n"
        }
        
        prompt += "\nDETAILED OBJECT POSITIONS:\n"
        for detection in detectionData {
            if let topLabel = detection["topLabel"] as? String,
               let confidence = detection["topConfidence"] as? Double,
               let position = detection["position"] as? [String: Any],
               let horizontal = position["horizontal"] as? String,
               let distance = position["distance"] as? String,
               let urgency = position["urgency"] as? String {
                
                prompt += "- \(topLabel) (\(String(format: "%.0f", confidence))%): \(horizontal), \(distance) - \(urgency)\n"
            }
        }
        
        prompt += """
        
        TASK: Analyze BOTH the object detection data above AND the actual camera image. Provide specific navigation guidance that includes:
        
        1. Identify the EXACT obstacles you see in the image
        2. Specify their PRECISE locations (left/right/center/distance)
        3. Give CLEAR directional guidance (which way to move)
        4. Mention any hazards the object detection might have missed
        
        Example good responses:
        - "Red car approaching from right, step to left curb immediately"
        - "Large tree trunk blocking center path, walk around to the right"
        - "Person with dog ahead on left sidewalk, stay right lane"
        - "Traffic cone and construction sign on right, use left walkway"
        
        Be SPECIFIC about what obstacles exist and WHERE they are located. Maximum 25 words.
        """
        
        return prompt
    }
    
    private func performVisionLanguageAPICall(requestData: [String: Any]) {
        guard let url = URL(string: "\(apiBaseURL)/chat/completions") else {
            print("❌ Invalid API URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestData)
            print("📤 Request payload size: \(request.httpBody?.count ?? 0) bytes")
        } catch {
            print("❌ Failed to serialize request data: \(error)")
            return
        }
        
        print("📤 Sending Vision-Language API request...")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("❌ API call failed: \(error)")
                self?.speakText("Navigation system temporarily unavailable, proceeding with caution.")
                return
            }
            
            guard let data = data else {
                print("❌ No data received from API")
                self?.speakText("No navigation data received, proceed carefully.")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 API Response Status: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode != 200 {
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("❌ API Error Response: \(responseString)")
                    }
                    
                    self?.speakText("Navigation analysis complete, path assessed.")
                    return
                }
            }
            
            do {
                if let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("📥 Vision-Language API Response received")
                    
                    if let choices = jsonResponse["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        
                        let cleanedContent = content
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "  ", with: " ")
                        
                        print("🗣️ Enhanced Navigation Guidance: \(cleanedContent)")
                        
                        self?.speakText(cleanedContent)
                        
                    } else {
                        print("❌ Unexpected response format")
                        print("Full response: \(jsonResponse)")
                        
                        self?.speakText("Path analysis complete, proceeding forward carefully.")
                    }
                }
            } catch {
                print("❌ Failed to parse API response: \(error)")
                if let responseString = String(data: data, encoding: .utf8) {
                    print("Raw response: \(responseString)")
                }
                
                self?.speakText("Navigation guidance ready, path ahead analyzed.")
            }
        }.resume()
    }
    
    // MARK: - Helper Functions
    private func convertPixelBufferToImageData(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("❌ Failed to create CGImage from pixel buffer")
            return nil
        }
        
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.7)
    }
    
    // MARK: - Enhanced TTS Implementation with Better Error Handling

    private func speakText(_ text: String) {
        print("🔊 Requesting TTS from Fanar API: \(text)")
        
        // Stop any currently playing audio
        audioPlayer?.stop()
        
        // Stop built-in speech synthesizer if it's running
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        
        // Use async queue for TTS request
        ttsQueue.async { [weak self] in
            self?.requestTTSFromFanar(text: text)
        }
    }

    // MARK: - Corrected TTS Implementation for Fanar API

    private func requestTTSFromFanar(text: String) {
        print("🚀 Starting TTS request for: \(text)")
        
        // ✅ FIXED: Correct URL construction with /audio/speech endpoint
        guard let url = URL(string: "\(apiBaseURL)/audio/speech") else {
            print("❌ Invalid TTS API URL: \(apiBaseURL)/audio/speech")
            fallbackToBuiltInTTS(text)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0
        
        // ✅ FIXED: Correct TTS request payload matching the working example
        let ttsRequest: [String: Any] = [
            "model": "Fanar-Aura-TTS-1",
            "input": text,
            "voice": "default"
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: ttsRequest)
            request.httpBody = jsonData
            
            // Log the request for debugging
            if let requestString = String(data: jsonData, encoding: .utf8) {
                print("📤 TTS Request Body: \(requestString)")
            }
            
            print("📤 Sending TTS request to: \(url)")
            
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                
                // Handle network errors
                if let error = error {
                    print("❌ TTS Network Error: \(error.localizedDescription)")
                    self?.fallbackToBuiltInTTS(text)
                    return
                }
                
                // Check if we received data
                guard let data = data else {
                    print("❌ No audio data received from TTS API")
                    self?.fallbackToBuiltInTTS(text)
                    return
                }
                
                print("📥 Received \(data.count) bytes of audio data")
                
                // Check HTTP response status
                if let httpResponse = response as? HTTPURLResponse {
                    print("📡 TTS API Response Status: \(httpResponse.statusCode)")
                    
                    if httpResponse.statusCode != 200 {
                        // Try to parse error response
                        if let responseString = String(data: data, encoding: .utf8) {
                            print("❌ TTS API Error Response: \(responseString)")
                        }
                        
                        // Handle specific error codes
                        switch httpResponse.statusCode {
                        case 401:
                            print("❌ Unauthorized - Check API key")
                        case 403:
                            print("❌ Forbidden - TTS endpoint might not be enabled")
                        case 404:
                            print("❌ Not Found - Check TTS endpoint URL")
                        case 429:
                            print("❌ Rate Limited - Too many requests")
                        case 500:
                            print("❌ Internal Server Error")
                        default:
                            print("❌ HTTP Error \(httpResponse.statusCode)")
                        }
                        
                        self?.fallbackToBuiltInTTS(text)
                        return
                    }
                }
                
                // ✅ The response should be direct audio data (MP3 format)
                // Check Content-Type header to verify it's audio
                if let httpResponse = response as? HTTPURLResponse,
                   let contentType = httpResponse.allHeaderFields["Content-Type"] as? String {
                    print("📊 Response Content-Type: \(contentType)")
                    
                    // Verify it's audio content
                    if !contentType.contains("audio") && !contentType.contains("octet-stream") {
                        print("❌ Unexpected content type, expected audio but got: \(contentType)")
                        self?.fallbackToBuiltInTTS(text)
                        return
                    }
                }
                
                // Try to play the audio data
                self?.playAudioData(data, originalText: text)
                
            }.resume()
            
        } catch {
            print("❌ Failed to serialize TTS request: \(error)")
            fallbackToBuiltInTTS(text)
        }
    }

    // ✅ Enhanced audio playback to handle MP3 format from Fanar API
    private func playAudioData(_ audioData: Data, originalText: String) {
        print("🎵 Attempting to play audio data: \(audioData.count) bytes")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            do {
                // Configure audio session BEFORE creating player
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
                try audioSession.setActive(true)
                print("✅ Audio session configured for playback")
                
                // Create audio player with the received data
                self.audioPlayer = try AVAudioPlayer(data: audioData)
                
                guard let player = self.audioPlayer else {
                    print("❌ Failed to create audio player")
                    self.fallbackToBuiltInTTS(originalText)
                    return
                }
                
                // Configure player
                player.delegate = self
                player.volume = 1.0
                player.prepareToPlay()
                
                print("🎵 Audio player created successfully")
                print("🎵 Audio duration: \(player.duration) seconds")
                
                // Play the audio
                let success = player.play()
                if success {
                    print("✅ Fanar TTS audio playback started for: \(originalText)")
                } else {
                    print("❌ Failed to start audio playback")
                    self.fallbackToBuiltInTTS(originalText)
                }
                
            } catch {
                print("❌ Failed to create/configure audio player: \(error)")
                print("❌ Error details: \(error.localizedDescription)")
                
                // Log more specific error information
                if let nsError = error as NSError? {
                    print("❌ Error domain: \(nsError.domain)")
                    print("❌ Error code: \(nsError.code)")
                    if nsError.domain == NSOSStatusErrorDomain {
                        print("❌ OSStatus error - likely audio format issue")
                    }
                }
                
                self.fallbackToBuiltInTTS(originalText)
            }
        }
    }

    // ✅ Test function you can call to verify TTS is working
    private func testFanarTTS() {
        print("🧪 Testing Fanar TTS...")
        speakText("Hello! This is a test of the Fanar text to speech API.")
    }
    
    private func fallbackToBuiltInTTS(_ text: String) {
        print("⚠️ Falling back to built-in TTS for: \(text)")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Stop any existing speech
            if self.speechSynthesizer.isSpeaking {
                self.speechSynthesizer.stopSpeaking(at: .immediate)
            }
            
            // Configure audio session for built-in TTS
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
                try audioSession.setActive(true)
            } catch {
                print("❌ Failed to configure audio session for built-in TTS: \(error)")
            }
            
            // Create and configure utterance
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9  // Slightly slower
            utterance.volume = 1.0
            utterance.pitchMultiplier = 1.0
            
            // Try to use a good English voice
            if let voice = AVSpeechSynthesisVoice(language: "en-US") {
                utterance.voice = voice
                print("✅ Using en-US voice for built-in TTS")
            } else {
                print("⚠️ Using default voice for built-in TTS")
            }
            
            print("🔊 Speaking with built-in TTS: \(text)")
            self.speechSynthesizer.speak(utterance)
        }
    }

    // MARK: - Audio Session Configuration
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true)
            print("✅ Audio session configured successfully for play and record")
        } catch {
            print("❌ Failed to configure audio session: \(error)")
        }
    }
    
    private func updateCropAndScaleOption() {
        let selectedIndex = cropAndScaleOptionSelector.selectedSegmentIndex
        cropAndScaleOption = VNImageCropAndScaleOption(rawValue: UInt(selectedIndex))!
        print("🔧 Crop and scale option: \(cropAndScaleOption)")
    }
    
    // MARK: - Actions
    @IBAction func modelBtnTapped(_ sender: UIButton) {
        showActionSheet()
    }
    
    @IBAction func cropAndScaleOptionChanged(_ sender: UISegmentedControl) {
        updateCropAndScaleOption()
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension ViewController: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        print("🔊 Speech started: \(utterance.speechString)")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("✅ Speech finished: \(utterance.speechString)")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        print("❌ Speech cancelled: \(utterance.speechString)")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let substring = (utterance.speechString as NSString).substring(with: characterRange)
        print("🗣️ Speaking: \(substring)")
    }
}

// MARK: - Enhanced AVAudioPlayerDelegate
extension ViewController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("✅ Fanar TTS audio finished playing successfully: \(flag)")
        if !flag {
            print("⚠️ Audio playback was not successful")
        }
        
        // Clean up
        audioPlayer = nil
        
        // Restore audio session
        configureAudioSession()
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error = error {
            print("❌ Audio player decode error: \(error)")
            if let nsError = error as NSError? {
                print("❌ Decode error domain: \(nsError.domain)")
                print("❌ Decode error code: \(nsError.code)")
            }
        }
        
        // Clean up and potentially retry with built-in TTS
        audioPlayer = nil
    }
    
    func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
        print("⚠️ Audio playback interrupted")
    }
    
    func audioPlayerEndInterruption(_ player: AVAudioPlayer, withOptions flags: Int) {
        print("✅ Audio interruption ended, resuming playback")
        player.play()
    }
}

// MARK: - Extensions
extension ViewController: UIPopoverPresentationControllerDelegate {
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "popover" {
            let vc = segue.destination
            vc.modalPresentationStyle = UIModalPresentationStyle.popover
            vc.popoverPresentationController!.delegate = self
        }
        
        if let modelDescriptionVC = segue.destination as? ModelDescriptionViewController, let model = selectedModel {
            modelDescriptionVC.modelDescription = model.modelDescription
        }
    }
    
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        return .none
    }
}

extension URL {
    var modelName: String {
        return lastPathComponent.replacingOccurrences(of: ".mlmodelc", with: "")
    }
}
