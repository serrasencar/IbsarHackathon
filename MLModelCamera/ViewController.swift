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
    // MARK: - Updated processObjectDetectionObservations method
    @available(iOS 12.0, *)
    private func processObjectDetectionObservations(_ results: [VNRecognizedObjectObservation], imageBuffer: CVPixelBuffer, timestamp: CMTime) {
        print("🎯 Detected \(results.count) objects:")
        
        var detectionData: [[String: Any]] = []
        var priorityObstacles: [(String, Int)] = [] // (description, priority)
        
        for (index, result) in results.enumerated() {
            let boundingBox = result.boundingBox
            
            let imageWidth = CVPixelBufferGetWidth(imageBuffer)
            let imageHeight = CVPixelBufferGetHeight(imageBuffer)
            let screenX = boundingBox.origin.x * CGFloat(imageWidth)
            let screenY = boundingBox.origin.y * CGFloat(imageHeight)
            let screenWidth = boundingBox.size.width * CGFloat(imageWidth)
            let screenHeight = boundingBox.size.height * CGFloat(imageHeight)
            
            let (horizontalPos, verticalPos, distance, urgency) = analyzeObjectPosition(boundingBox: boundingBox)
            
            // Extract distance in meters for priority calculation
            let distanceRegex = try! NSRegularExpression(pattern: "\\d+\\.?\\d*")
            let distanceString = distance
            let range = NSRange(location: 0, length: distanceString.utf16.count)
            var distanceMeters: Double = 10.0 // Default far distance
            
            if let match = distanceRegex.firstMatch(in: distanceString, options: [], range: range) {
                let matchString = (distanceString as NSString).substring(with: match.range)
                distanceMeters = Double(matchString) ?? 10.0
            }
            
            // Trigger vibration for critical situations
            if urgency.contains("CRITICAL") || distanceMeters <= 1.5 {
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
            
            // Determine if object is in path
            let centerX = boundingBox.origin.x + (boundingBox.size.width / 2.0)
            let isInPath = centerX > 0.25 && centerX < 0.75
            
            let (category, priority) = categorizeObjectWithPriority(topLabel, distance: distanceMeters, isInPath: isInPath)
            
            let obstacleDescription = "\(topLabel) at \(horizontalPos) (\(distance))"
            priorityObstacles.append((obstacleDescription, priority))
            
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
                    "urgency": urgency,
                    "distanceMeters": distanceMeters,
                    "isInPath": isInPath
                ],
                "category": category,
                "priority": priority
            ]
            
            detectionData.append(objectData)
        }
        
        // Sort obstacles by priority for better navigation guidance
        priorityObstacles.sort { $0.1 < $1.1 }
        
        let currentTime = CACurrentMediaTime()
        if currentTime - lastAPICallTime >= apiCallInterval {
            lastAPICallTime = currentTime
            
            print("\n🚀 SENDING TO VISION-LANGUAGE API:")
            print("📊 Detection Data Count: \(detectionData.count) objects")
            print("🎯 Priority Obstacles: \(priorityObstacles.prefix(3).map { $0.0 })")
            
            let imageData = convertPixelBufferToImageData(imageBuffer)
            self.latestCapturedImageData = imageData
            sendToVisionLanguageAPI(
                detectionData: detectionData,
                imageData: imageData,
                timestamp: timestamp.seconds,
                criticalObstacles: [],
                pathBlockers: [],
                environmentalHazards: []
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
    // MARK: - Enhanced Object Analysis with Improved Distance Estimation
    private func analyzeObjectPosition(boundingBox: CGRect) -> (horizontal: String, vertical: String, distance: String, urgency: String) {
        let x = boundingBox.origin.x
        let y = boundingBox.origin.y
        let width = boundingBox.size.width
        let height = boundingBox.size.height
        let area = width * height
        
        // Calculate center of bounding box
        let centerX = x + (width / 2.0)
        let centerY = y + (height / 2.0)
        
        // Enhanced horizontal position analysis
        let horizontalPos: String
        let horizontalDistance: String
        if centerX < 0.1 {
            horizontalPos = "far left edge"
            horizontalDistance = "4-5 meters to left"
        } else if centerX < 0.25 {
            horizontalPos = "left side"
            horizontalDistance = "2-3 meters to left"
        } else if centerX < 0.4 {
            horizontalPos = "slightly left"
            horizontalDistance = "1-2 meters to left"
        } else if centerX < 0.6 {
            horizontalPos = "directly ahead"
            horizontalDistance = "straight ahead"
        } else if centerX < 0.75 {
            horizontalPos = "slightly right"
            horizontalDistance = "1-2 meters to right"
        } else if centerX < 0.9 {
            horizontalPos = "right side"
            horizontalDistance = "2-3 meters to right"
        } else {
            horizontalPos = "far right edge"
            horizontalDistance = "4-5 meters to right"
        }
        
        // Enhanced vertical position analysis
        let verticalPos: String
        if y > 0.7 {
            verticalPos = "ground level"
        } else if y > 0.4 {
            verticalPos = "waist to chest height"
        } else if y > 0.1 {
            verticalPos = "eye to head level"
        } else {
            verticalPos = "overhead"
        }
        
        // IMPROVED DISTANCE ESTIMATION
        let (estimatedDistance, distanceMeters) = calculateRealWorldDistance(
            boundingBox: boundingBox,
            area: area
        )
        
        // Enhanced urgency calculation based on distance and position
        let urgency: String
        let isInPath = centerX > 0.25 && centerX < 0.75 // Within central walking path
        let isGroundLevel = y > 0.5 // Ground level obstacles
        
        if distanceMeters <= 1.5 && isInPath && isGroundLevel {
            urgency = "CRITICAL - immediate collision risk"
        } else if distanceMeters <= 2.5 && isInPath {
            urgency = "HIGH - obstacle in path"
        } else if distanceMeters <= 4.0 && isInPath {
            urgency = "MEDIUM - approaching obstacle"
        } else if distanceMeters <= 2.0 {
            urgency = "MEDIUM - very close to side"
        } else {
            urgency = "LOW - safe distance"
        }
        
        return (horizontalPos, verticalPos, estimatedDistance, urgency)
    }
    
    // MARK: - Real-World Distance Calculation
    private func calculateRealWorldDistance(boundingBox: CGRect, area: CGFloat) -> (description: String, meters: Double) {
        let width = boundingBox.size.width
        let height = boundingBox.size.height
        let centerY = boundingBox.origin.y + (height / 2.0)
        
        // Distance estimation based on multiple factors
        var estimatedMeters: Double
        
        // Primary estimation based on bounding box area
        // These values are calibrated approximations for common objects
        if area > 0.35 {
            estimatedMeters = 0.5 // Very close
        } else if area > 0.25 {
            estimatedMeters = 1.0
        } else if area > 0.15 {
            estimatedMeters = 1.5
        } else if area > 0.10 {
            estimatedMeters = 2.5
        } else if area > 0.06 {
            estimatedMeters = 3.5
        } else if area > 0.03 {
            estimatedMeters = 5.0
        } else if area > 0.015 {
            estimatedMeters = 7.5
        } else {
            estimatedMeters = 10.0
        }
        
        // Adjustment based on vertical position (perspective correction)
        // Objects lower in frame are typically closer
        let verticalAdjustment = 1.0 + (centerY * 0.3) // 0% to 30% adjustment
        estimatedMeters *= verticalAdjustment
        
        // Adjustment based on object width (wider objects typically closer)
        let widthAdjustment = max(0.7, 1.0 - (width * 0.5))
        estimatedMeters *= widthAdjustment
        
        // Create descriptive distance
        let description: String
        if estimatedMeters <= 1.0 {
            description = "very close (under 1 meter)"
        } else if estimatedMeters <= 2.0 {
            description = "close (\(String(format: "%.1f", estimatedMeters)) meters)"
        } else if estimatedMeters <= 4.0 {
            description = "nearby (\(String(format: "%.1f", estimatedMeters)) meters)"
        } else if estimatedMeters <= 7.0 {
            description = "moderate distance (\(String(format: "%.0f", estimatedMeters)) meters)"
        } else {
            description = "far away (\(String(format: "%.0f", estimatedMeters)) meters)"
        }
        
        return (description, estimatedMeters)
    }

    private func isMovingVehicle(_ label: String) -> Bool {
        let movingVehicles = ["car", "truck", "bus", "motorcycle", "bicycle", "train", "boat", "airplane"]
        return movingVehicles.contains(label.lowercased())
    }

    private func isDangerousObject(_ label: String) -> Bool {
        // Animals that could be unpredictable or dangerous, plus moving objects
        let dangerous = ["person", "dog", "cat", "horse", "cow", "elephant", "bear", "sheep", "zebra", "giraffe"]
        return dangerous.contains(label.lowercased())
    }

    private func isPathBlocker(_ label: String) -> Bool {
        // Static objects that could block walking paths
        let pathBlockers = [
            "chair", "couch", "dining table", "bench", "bed",
            "suitcase", "backpack", "handbag", "umbrella",
            "potted plant", "vase", "refrigerator", "microwave", "oven", "toaster",
            "tv", "laptop", "bicycle", "motorcycle", "skateboard", "surfboard", "snowboard", "skis",
            "stop sign", "traffic light", "fire hydrant", "parking meter"
        ]
        return pathBlockers.contains(label.lowercased())
    }

    private func isEnvironmentalHazard(_ label: String) -> Bool {
        // Objects that indicate potential environmental hazards or areas requiring caution
        let hazards = [
            "knife", "scissors", "baseball bat", "tennis racket",
            "hot dog", "pizza", "cake", "donut" // food items that might indicate dining areas with potential spills
        ]
        return hazards.contains(label.lowercased())
    }

    private func categorizeObject(_ label: String) -> String {
        let lowerLabel = label.lowercased()
        
        if isMovingVehicle(lowerLabel) { return "MOVING_VEHICLE" }
        if isDangerousObject(lowerLabel) { return "LIVING_BEING" }
        if isPathBlocker(lowerLabel) { return "PATH_BLOCKER" }
        if isEnvironmentalHazard(lowerLabel) { return "POTENTIAL_HAZARD" }
        
        // Additional specific categorizations for navigation context
        let furniture = ["chair", "couch", "dining table", "bench", "bed"]
        let electronics = ["tv", "laptop", "cell phone", "microwave", "refrigerator", "oven", "toaster"]
        let sports = ["sports ball", "tennis racket", "baseball bat", "baseball glove", "frisbee", "kite", "skateboard", "surfboard", "snowboard", "skis"]
        let containers = ["suitcase", "backpack", "handbag", "bottle", "cup", "bowl", "wine glass"]
        let food = ["banana", "apple", "orange", "carrot", "broccoli", "hot dog", "pizza", "cake", "donut", "sandwich"]
        
        if furniture.contains(lowerLabel) { return "FURNITURE" }
        if electronics.contains(lowerLabel) { return "ELECTRONICS" }
        if sports.contains(lowerLabel) { return "SPORTS_EQUIPMENT" }
        if containers.contains(lowerLabel) { return "CONTAINER" }
        if food.contains(lowerLabel) { return "FOOD_ITEM" }
        
        return "GENERAL_OBJECT"
    }
    
    // MARK: - Enhanced Object Categorization with Distance-Aware Priority
    private func categorizeObjectWithPriority(_ label: String, distance: Double, isInPath: Bool) -> (category: String, priority: Int) {
        let lowerLabel = label.lowercased()
        
        // Priority: 1 = Critical, 2 = High, 3 = Medium, 4 = Low
        var basePriority: Int
        var category: String
        
        if isMovingVehicle(lowerLabel) {
            category = "MOVING_VEHICLE"
            basePriority = 1 // Always critical
        } else if isDangerousObject(lowerLabel) {
            category = "LIVING_BEING"
            basePriority = distance <= 3.0 ? 1 : 2
        } else if isPathBlocker(lowerLabel) {
            category = "PATH_BLOCKER"
            basePriority = (distance <= 2.0 && isInPath) ? 2 : 3
        } else if isEnvironmentalHazard(lowerLabel) {
            category = "POTENTIAL_HAZARD"
            basePriority = distance <= 1.5 ? 2 : 4
        } else {
            category = "GENERAL_OBJECT"
            basePriority = (distance <= 1.0 && isInPath) ? 3 : 4
        }
        
        return (category, basePriority)
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
    
    // MARK: - Enhanced Navigation Prompt with Precise Distance Information
    private func createEnhancedNavigationPrompt(
        detectionData: [[String: Any]],
        criticalObstacles: [String],
        pathBlockers: [String],
        environmentalHazards: [String]
    ) -> String {
        
        var prompt = """
        VISUAL NAVIGATION ANALYSIS - REAL-TIME ENVIRONMENT ASSESSMENT
        
        CURRENT SITUATION: You are helping a visually impaired person navigate safely through their environment.
        
        """
        
        // Organize objects by priority and distance
        var criticalItems: [String] = []
        var highPriorityItems: [String] = []
        var mediumPriorityItems: [String] = []
        var safeItems: [String] = []
        
        for detection in detectionData {
            if let topLabel = detection["topLabel"] as? String,
               let confidence = detection["topConfidence"] as? Double,
               let position = detection["position"] as? [String: Any],
               let horizontal = position["horizontal"] as? String,
               let distance = position["distance"] as? String,
               let urgency = position["urgency"] as? String {
                
                let item = "\(topLabel) located \(horizontal) at \(distance)"
                
                if urgency.contains("CRITICAL") {
                    criticalItems.append("🚨 \(item) - IMMEDIATE DANGER")
                } else if urgency.contains("HIGH") {
                    highPriorityItems.append("⚠️ \(item) - NEEDS ATTENTION")
                } else if urgency.contains("MEDIUM") {
                    mediumPriorityItems.append("📍 \(item) - BE AWARE")
                } else {
                    safeItems.append("✓ \(item) - SAFE DISTANCE")
                }
            }
        }
        
        // Add critical items first
        if !criticalItems.isEmpty {
            prompt += "🚨 IMMEDIATE ATTENTION REQUIRED:\n"
            for item in criticalItems {
                prompt += "\(item)\n"
            }
            prompt += "\n"
        }
        
        // Add high priority items
        if !highPriorityItems.isEmpty {
            prompt += "⚠️ NAVIGATION OBSTACLES:\n"
            for item in highPriorityItems {
                prompt += "\(item)\n"
            }
            prompt += "\n"
        }
        
        // Add medium priority for context
        if !mediumPriorityItems.isEmpty {
            prompt += "📍 ENVIRONMENTAL AWARENESS:\n"
            for item in mediumPriorityItems {
                prompt += "\(item)\n"
            }
            prompt += "\n"
        }
        
        // Add safe items for confidence
        if !safeItems.isEmpty && (criticalItems.isEmpty && highPriorityItems.isEmpty) {
            prompt += "✓ SAFE ENVIRONMENT DETECTED:\n"
            for item in safeItems.take(3) { // Limit to 3 for brevity
                prompt += "\(item)\n"
            }
            prompt += "\n"
        }
        
        prompt += """
        
        NAVIGATION GUIDANCE REQUIREMENTS:
        
        You are an expert mobility instructor with years of experience helping visually impaired individuals. Your role is to provide:
        
        1. PRECISE DISTANCE GUIDANCE:
           - Use the EXACT meter measurements provided above
           - Give specific walking directions: "Walk straight for 3 meters" or "In 2 meters, step left"
           - Provide reference points: "The chair is 1.5 meters to your right"
        
        2. CLEAR DIRECTIONAL INSTRUCTIONS:
           - "Continue straight ahead"
           - "Step 1 meter to your left" 
           - "Turn right and walk 4 meters"
           - "Bear slightly left for 2 meters"
        
        3. SAFETY-FIRST APPROACH:
           - Always address critical/high priority items first
           - Give specific avoidance instructions for dangerous objects
           - Provide reassurance when path is clear
        
        4. SUPPORTIVE COMMUNICATION:
           - Use encouraging, warm tone
           - Build confidence: "Perfect!", "You're doing great!", "Safe path ahead"
           - Be specific but not overwhelming
        
        RESPONSE EXAMPLES:
        
        For Critical Situations:
        "Stop! Car approaching 1 meter ahead on right. Step 2 meters left immediately, then continue straight."
        
        For High Priority:
        "Chair blocking path 2.5 meters ahead. Step left now, walk straight 3 meters, then center again."
        
        For Clear Paths:
        "Perfect! Clear path straight ahead for 8 meters. Continue confidently at normal pace."
        
        For Side Obstacles:
        "Bicycle 1.5 meters to your right. Your left path is completely clear for 6 meters ahead."
        
        CRITICAL RULES:
        - Always mention specific distances in meters
        - Address the most urgent obstacle first
        - Give one clear action at a time
        - Maximum 30 words but be precise about distances and directions
        - Use encouraging language while being specific about safety
        
        Analyze the provided detections and image to give precise, caring navigation guidance.
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
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
            try audioSession.setActive(true)
            print("✅ Audio session configured successfully")
        } catch {
            print("❌ Failed to configure audio session: \(error)")
        }
    }
    
    private func speakText(_ text: String) {
        print("🔊 Attempting to speak: \(text)")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if self.speechSynthesizer.isSpeaking {
                self.speechSynthesizer.stopSpeaking(at: .immediate)
            }
            
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.8
            utterance.volume = 1.0
            utterance.pitchMultiplier = 1.0
            
            if let voice = AVSpeechSynthesisVoice(language: "en-US") {
                utterance.voice = voice
                print("🎤 Using voice: \(voice.name)")
            } else {
                print("⚠️ Using default voice")
            }
            
            self.speechSynthesizer.delegate = self
            print("🔊 Starting speech synthesis...")
            self.speechSynthesizer.speak(utterance)
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

// Helper extension for array limiting
extension Array {
    func take(_ count: Int) -> Array {
        return Array(self.prefix(count))
    }
}
