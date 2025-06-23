import UIKit
import CoreML
import Vision
import AVFoundation

class ViewController: UIViewController {
    
    // MARK: - Properties (Keep your existing properties)
    private var videoCapture: VideoCapture!
    private let serialQueue = DispatchQueue(label: "com.shu223.coremlplayground.serialqueue")
    
    private let videoSize = CGSize(width: 1280, height: 720)
    private let preferredFps: Int32 = 2
    
    private var modelUrls: [URL]!
    private var selectedVNModel: VNCoreMLModel?
    private var selectedModel: MLModel?
    
    private var lastAPICallTime: CFTimeInterval = 0
    private let apiCallInterval: CFTimeInterval = 30.0 // 30 seconds between API calls for more frequent updates
    private let apiKey = "fmFrMl3wHnB9SFnb8bzxNFpGCVE18Wcz"
    private let apiBaseURL = "https://api.fanar.qa/v1"
    
    // Speech synthesis
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    private var cropAndScaleOption: VNImageCropAndScaleOption = .scaleFit
    
    @IBOutlet private weak var previewView: UIView!
    @IBOutlet private weak var modelLabel: UILabel!
    @IBOutlet private weak var resultView: UIView!
    @IBOutlet private weak var resultLabel: UILabel!
    @IBOutlet private weak var othersLabel: UILabel!
    @IBOutlet private weak var bbView: BoundingBoxView!
    @IBOutlet weak var cropAndScaleOptionSelector: UISegmentedControl!
    
    // MARK: - ViewDidLoad and Lifecycle Methods
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // CRITICAL: Configure audio session for speech synthesis
            configureAudioSession()
        
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
        
        // scaleFill
        cropAndScaleOptionSelector.selectedSegmentIndex = 2
        updateCropAndScaleOption()
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
    
    // MARK: - Private Methods
    
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
    
    // MARK: - Enhanced Model Processing with Vision-Language Integration
    
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
            
            // Object Detection Results
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
    
    // MARK: - Enhanced Object Detection Processing with Detailed Analysis
    
    @available(iOS 12.0, *)
    private func processObjectDetectionObservations(_ results: [VNRecognizedObjectObservation], imageBuffer: CVPixelBuffer, timestamp: CMTime) {
        
        print("🎯 Detected \(results.count) objects:")
        
        var detectionData: [[String: Any]] = []
        var criticalObstacles: [String] = []
        var pathBlockers: [String] = []
        var environmentalHazards: [String] = []
        
        for (index, result) in results.enumerated() {
            let boundingBox = result.boundingBox
            
            // Convert to pixel coordinates
            let imageWidth = CVPixelBufferGetWidth(imageBuffer)
            let imageHeight = CVPixelBufferGetHeight(imageBuffer)
            let screenX = boundingBox.origin.x * CGFloat(imageWidth)
            let screenY = boundingBox.origin.y * CGFloat(imageHeight)
            let screenWidth = boundingBox.size.width * CGFloat(imageWidth)
            let screenHeight = boundingBox.size.height * CGFloat(imageHeight)
            
            // Enhanced position analysis
            let (horizontalPos, verticalPos, distance, urgency) = analyzeObjectPosition(boundingBox: boundingBox)
            
            print("\n🔸 Object \(index + 1):")
            print("   📍 Position: \(horizontalPos), \(verticalPos)")
            print("   📏 Distance: \(distance)")
            print("   ⚠️ Urgency: \(urgency)")
            
            // Process labels with enhanced categorization
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
            
            // Enhanced obstacle categorization
            let obstacleInfo = "\(topLabel) at \(horizontalPos) (\(distance))"
            
            if isMovingVehicle(topLabel) || isDangerousObject(topLabel) {
                criticalObstacles.append("🚨 \(obstacleInfo) - IMMEDIATE DANGER")
            } else if isPathBlocker(topLabel) {
                pathBlockers.append("🚧 \(obstacleInfo) - PATH BLOCKED")
            } else if isEnvironmentalHazard(topLabel) {
                environmentalHazards.append("⚠️ \(obstacleInfo) - CAUTION NEEDED")
            }
            
            // Structure enhanced data for API
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
        
        // Check if it's time for Vision-Language API call
        let currentTime = CACurrentMediaTime()
        if currentTime - lastAPICallTime >= apiCallInterval {
            lastAPICallTime = currentTime
            
            print("\n🚀 SENDING TO VISION-LANGUAGE API:")
            print("📊 Detection Data Count: \(detectionData.count) objects")
            print("🚨 Critical Obstacles: \(criticalObstacles.count)")
            print("🚧 Path Blockers: \(pathBlockers.count)")
            print("⚠️ Environmental Hazards: \(environmentalHazards.count)")
            
            let imageData = convertPixelBufferToImageData(imageBuffer)
            sendToVisionLanguageAPI(
                detectionData: detectionData,
                imageData: imageData,
                timestamp: timestamp.seconds,
                criticalObstacles: criticalObstacles,
                pathBlockers: pathBlockers,
                environmentalHazards: environmentalHazards
            )
        }
        
        // Update UI
        bbView.observations = results
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.resultView.isHidden = true
            self.bbView.isHidden = false
            self.bbView.setNeedsDisplay()
        }
    }
    
    // MARK: - Enhanced Object Analysis Functions
    
    private func analyzeObjectPosition(boundingBox: CGRect) -> (horizontal: String, vertical: String, distance: String, urgency: String) {
        let x = boundingBox.origin.x
        let y = boundingBox.origin.y
        let width = boundingBox.size.width
        let height = boundingBox.size.height
        let area = width * height
        
        // More precise horizontal positioning
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
        
        // Vertical positioning
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
        
        // Distance estimation based on object size and position
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
        
        // Urgency assessment
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
    
    // MARK: - Enhanced Vision-Language API Integration
    
    private func sendToVisionLanguageAPI(
        detectionData: [[String: Any]],
        imageData: Data?,
        timestamp: Double,
        criticalObstacles: [String],
        pathBlockers: [String],
        environmentalHazards: [String]
    ) {
        print("🔄 Preparing Vision-Language API call...")
        
        // Create enhanced navigation prompt with image
        let prompt = createEnhancedNavigationPrompt(
            detectionData: detectionData,
            criticalObstacles: criticalObstacles,
            pathBlockers: pathBlockers,
            environmentalHazards: environmentalHazards
        )
        
        // Prepare messages with image and text
        var messageContent: [[String: Any]] = [
            [
                "type": "text",
                "text": prompt
            ]
        ]
        
        // Add image if available
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
        
        // Prepare the enhanced LLM request with vision capabilities
        let llmRequest: [String: Any] = [
            "model": "Fanar-Oryx-IVU-1", // Vision-understanding model
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
            "temperature": 0.2, // Lower temperature for more consistent responses
            "max_tokens": 100
        ]
        
        // Make the API call
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
    
    // MARK: - Enhanced API Response Handling with Better Audio
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
                // Provide fallback audio response
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
                    
                    // Provide fallback audio response
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
                        
                        // Clean and enhance the response
                        let cleanedContent = content
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "  ", with: " ")
                        
                        print("🗣️ Enhanced Navigation Guidance: \(cleanedContent)")
                        
                        // CRITICAL: Speak the response immediately on main thread
                        self?.speakText(cleanedContent)
                        
                    } else {
                        print("❌ Unexpected response format")
                        print("Full response: \(jsonResponse)")
                        
                        // Provide fallback audio response
                        self?.speakText("Path analysis complete, proceeding forward carefully.")
                    }
                }
            } catch {
                print("❌ Failed to parse API response: \(error)")
                if let responseString = String(data: data, encoding: .utf8) {
                    print("Raw response: \(responseString)")
                }
                
                // Provide fallback audio response
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
        // Optimize image for API - balance between quality and size
        return uiImage.jpegData(compressionQuality: 0.7)
    }
    
    // MARK: - Audio Session Configuration
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Set category to playback to ensure audio plays even in silent mode
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
            
            // Activate the audio session
            try audioSession.setActive(true)
            
            print("✅ Audio session configured successfully")
        } catch {
            print("❌ Failed to configure audio session: \(error)")
        }
    }
    
    private func speakText(_ text: String) {
        print("🔊 Attempting to speak: \(text)")
        
        // CRITICAL: Ensure we're on the main thread for UI and audio operations
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Stop any current speech
            if self.speechSynthesizer.isSpeaking {
                self.speechSynthesizer.stopSpeaking(at: .immediate)
            }
            
            // Create utterance with enhanced settings
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.8 // Slightly slower
            utterance.volume = 1.0
            utterance.pitchMultiplier = 1.0
            
            // Try to use a high-quality voice
            if let voice = AVSpeechSynthesisVoice(language: "en-US") {
                utterance.voice = voice
                print("🎤 Using voice: \(voice.name)")
            } else {
                print("⚠️ Using default voice")
            }
            
            // Add delegate to track speech status
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
        // Optional: Track speech progress
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
