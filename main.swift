import SwiftUI
import SpriteKit
import AVFoundation
import CoreImage
import AppKit

// Extension to support Color.magenta on older macOS versions
extension Color {
    static let magenta = Color(NSColor.magenta)
}

// MARK: - Enums & Model Definitions

enum GameState {
    case menu
    case countdown
    case playing
    case paused
    case gameOver
}

enum AIDifficulty: String, CaseIterable, Identifiable {
    case easy = "Easy"
    case medium = "Medium"
    case hard = "Hard"
    case impossible = "Impossible"
    
    var id: String { self.rawValue }
}

enum ControlMode: String, CaseIterable, Identifiable {
    case mouse = "Mouse"
    case keyboard = "Keyboard"
    
    var id: String { self.rawValue }
}

enum GameMode: String, CaseIterable, Identifiable {
    case classic = "Classic"
    case neonStorm = "Neon Storm"
    case zen = "Zen"
    
    var id: String { self.rawValue }
}

class GameViewModel: ObservableObject {
    @Published var leftScore = 0
    @Published var rightScore = 0
    @Published var gameState: GameState = .menu
    @Published var winnerName = ""
    @Published var fps: Int = 0
    @Published var countdownVal = 3
    
    // Game configurations (bindable to sliders)
    @Published var isPlayerVsCPU = true
    @Published var aiDifficulty: AIDifficulty = .medium
    @Published var controlMode: ControlMode = .mouse
    @Published var gameMode: GameMode = .classic
    
    @Published var glowIntensity: Float = 1.2
    @Published var shakeMultiplier: Float = 1.0
    @Published var ballSpeed: Float = 8.0
    @Published var maxBallSpeed: Float = 22.0
    @Published var ballSpeedIncrement: Float = 0.6
    @Published var bounceRandomness: Float = 0.5 // range 0 to 2
    @Published var soundType: String = "sine" // sine, square, triangle, off
    @Published var soundVolume: Float = 0.5
}

// MARK: - Dynamic Audio Synthesizer

class SoundSynth {
    static let shared = SoundSynth()
    
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isEngineStarted = false
    
    init() {
        setupAudioEngine()
    }
    
    private func setupAudioEngine() {
        engine.attach(player)
        
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        
        do {
            try engine.start()
            isEngineStarted = true
        } catch {
            print("SoundSynth: Failed to start audio engine: \(error)")
        }
        
        // Handle audio hardware route changes safely
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restartEngineIfNeeded()
        }
    }
    
    private func restartEngineIfNeeded() {
        if !engine.isRunning {
            do {
                try engine.start()
                isEngineStarted = true
            } catch {
                print("SoundSynth: Failed to restart audio engine: \(error)")
            }
        }
    }
    
    func playBeep(frequency: Float, duration: Double, type: String, volume: Float = 0.5) {
        guard type != "off", isEngineStarted else { return }
        restartEngineIfNeeded()
        
        let sampleRate = Float(44100.0)
        let frameCount = AVAudioFrameCount(duration * Double(sampleRate))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        
        buffer.frameLength = frameCount
        let channels = buffer.floatChannelData?[0]
        
        for i in 0..<Int(frameCount) {
            let t = Float(i) / sampleRate
            var val: Float = 0
            
            if type == "sine" {
                val = sin(2.0 * .pi * frequency * t)
            } else if type == "square" {
                val = sin(2.0 * .pi * frequency * t) >= 0.0 ? 0.15 : -0.15
            } else if type == "triangle" {
                // Triangle wave formula
                val = asin(sin(2.0 * .pi * frequency * t)) * (2.0 / .pi) * 0.3
            }
            
            // Fade-out envelope to prevent speaker clicks
            let envelope: Float
            let fadeFrames = Int(sampleRate * 0.015) // 15ms fade out
            let remaining = Int(frameCount) - i
            if remaining < fadeFrames {
                envelope = Float(remaining) / Float(fadeFrames)
            } else if i < fadeFrames {
                envelope = Float(i) / Float(fadeFrames)
            } else {
                envelope = 1.0
            }
            
            channels?[i] = val * envelope * volume
        }
        
        player.play()
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }
    
    func playScoreSound(volume: Float = 0.5, type: String) {
        // High ascending digital arpeggio
        let notes: [Float] = [523.25, 659.25, 783.99, 1046.50] // C5, E5, G5, C6
        var delay = 0.0
        for note in notes {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.playBeep(frequency: note, duration: 0.08, type: type, volume: volume)
            }
            delay += 0.06
        }
    }
    
    func playWinSound(volume: Float = 0.5, type: String) {
        let notes: [Float] = [523.25, 659.25, 783.99, 1046.50, 1318.51, 1567.98, 2093.00]
        var delay = 0.0
        for note in notes {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.playBeep(frequency: note, duration: 0.12, type: type, volume: volume)
            }
            delay += 0.08
        }
    }
    
    func playLoseSound(volume: Float = 0.5, type: String) {
        let notes: [Float] = [392.00, 349.23, 311.13, 261.63] // G4, F4, Eb4, C4 descending
        var delay = 0.0
        for note in notes {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.playBeep(frequency: note, duration: 0.2, type: type, volume: volume)
            }
            delay += 0.15
        }
    }
}

// MARK: - SpriteKit Gameplay Scene

class GameScene: SKScene, SKPhysicsContactDelegate {
    weak var viewModel: GameViewModel?
    
    // Core game components
    private var bloomNode: SKEffectNode!
    private var worldNode: SKNode!
    private var ball: SKShapeNode!
    private var leftPaddle: SKShapeNode!
    private var rightPaddle: SKShapeNode!
    private var borderTop: SKShapeNode!
    private var borderBottom: SKShapeNode!
    private var centerLine: SKShapeNode!
    private var obstacles: [SKShapeNode] = []
    
    // State tracking
    private var isInitialized = false
    private var pressedKeys = Set<UInt16>()
    private var savedVelocity: CGVector = .zero
    private var shakeIntensity: CGFloat = 0.0
    private var ballTrail: SKEmitterNode?
    
    // Game stats
    private var leftScore = 0
    private var rightScore = 0
    private let winningScore = 7
    
    // FPS tracking
    private var lastUpdateTime: TimeInterval = 0
    private var frameCount = 0
    private var fpsTimer: TimeInterval = 0
    
    override func didMove(to view: SKView) {
        self.backgroundColor = .black
        
        // Setup Physics World
        self.physicsWorld.gravity = .zero
        self.physicsWorld.contactDelegate = self
        
        // Setup Camera for screen shake
        let cam = SKCameraNode()
        self.camera = cam
        self.addChild(cam)
        cam.position = CGPoint(x: size.width / 2, y: size.height / 2)
        
        // Setup Bloom (HDR Glow Effect)
        bloomNode = SKEffectNode()
        bloomNode.shouldEnableEffects = true
        addChild(bloomNode)
        updateGlow()
        
        // Setup World Node (where all game elements reside)
        worldNode = SKNode()
        bloomNode.addChild(worldNode)
        
        setupArena()
        setupPaddles()
        setupBall()
        
        // Key input configuration
        view.window?.makeFirstResponder(self)
        
        isInitialized = true
        startNewGame()
    }
    
    override var acceptsFirstResponder: Bool { true }
    
    // MARK: - Scene Building
    
    private func setupArena() {
        let margin: CGFloat = 20.0
        
        // Top Border
        borderTop = SKShapeNode(rectOf: CGSize(width: size.width - margin*2, height: 6), cornerRadius: 3)
        borderTop.position = CGPoint(x: size.width / 2, y: size.height - margin)
        styleNeonNode(borderTop, color: .cyan)
        borderTop.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: size.width - margin*2, height: 6))
        borderTop.physicsBody?.isDynamic = false
        borderTop.physicsBody?.restitution = 1.0
        borderTop.physicsBody?.friction = 0.0
        borderTop.physicsBody?.categoryBitMask = 0x1
        borderTop.physicsBody?.collisionBitMask = 0x1
        borderTop.name = "wall"
        worldNode.addChild(borderTop)
        
        // Bottom Border
        borderBottom = SKShapeNode(rectOf: CGSize(width: size.width - margin*2, height: 6), cornerRadius: 3)
        borderBottom.position = CGPoint(x: size.width / 2, y: margin)
        styleNeonNode(borderBottom, color: .cyan)
        borderBottom.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: size.width - margin*2, height: 6))
        borderBottom.physicsBody?.isDynamic = false
        borderBottom.physicsBody?.restitution = 1.0
        borderBottom.physicsBody?.friction = 0.0
        borderBottom.physicsBody?.categoryBitMask = 0x1
        borderBottom.physicsBody?.collisionBitMask = 0x1
        borderBottom.name = "wall"
        worldNode.addChild(borderBottom)
        
        // Center Dashed Line
        let path = CGMutablePath()
        let startY = margin + 10
        let endY = size.height - margin - 10
        let dashes: [CGFloat] = [15, 15]
        
        path.move(to: CGPoint(x: size.width / 2, y: startY))
        path.addLine(to: CGPoint(x: size.width / 2, y: endY))
        
        let dashedPath = path.copy(dashingWithPhase: 0, lengths: dashes)
        centerLine = SKShapeNode(path: dashedPath)
        centerLine.strokeColor = NSColor.cyan.withAlphaComponent(0.25)
        centerLine.lineWidth = 4
        worldNode.addChild(centerLine)
    }
    
    private func setupPaddles() {
        let paddleSize = CGSize(width: 16, height: 100)
        
        // Left Paddle (Player 1)
        leftPaddle = SKShapeNode(rectOf: paddleSize, cornerRadius: 8)
        leftPaddle.position = CGPoint(x: 60, y: size.height / 2)
        styleNeonNode(leftPaddle, color: .cyan)
        leftPaddle.physicsBody = SKPhysicsBody(rectangleOf: paddleSize)
        leftPaddle.physicsBody?.isDynamic = false
        leftPaddle.physicsBody?.restitution = 1.0
        leftPaddle.physicsBody?.friction = 0.0
        leftPaddle.physicsBody?.categoryBitMask = 0x1
        leftPaddle.physicsBody?.collisionBitMask = 0x1
        leftPaddle.name = "leftPaddle"
        worldNode.addChild(leftPaddle)
        
        // Right Paddle (CPU or Player 2)
        rightPaddle = SKShapeNode(rectOf: paddleSize, cornerRadius: 8)
        rightPaddle.position = CGPoint(x: size.width - 60, y: size.height / 2)
        styleNeonNode(rightPaddle, color: .magenta)
        rightPaddle.physicsBody = SKPhysicsBody(rectangleOf: paddleSize)
        rightPaddle.physicsBody?.isDynamic = false
        rightPaddle.physicsBody?.restitution = 1.0
        rightPaddle.physicsBody?.friction = 0.0
        rightPaddle.physicsBody?.categoryBitMask = 0x1
        rightPaddle.physicsBody?.collisionBitMask = 0x1
        rightPaddle.name = "rightPaddle"
        worldNode.addChild(rightPaddle)
    }
    
    private func setupBall() {
        ball = SKShapeNode(circleOfRadius: 9)
        ball.position = CGPoint(x: size.width / 2, y: size.height / 2)
        styleNeonNode(ball, color: .yellow)
        
        // Physics Body
        ball.physicsBody = SKPhysicsBody(circleOfRadius: 9)
        ball.physicsBody?.isDynamic = true
        ball.physicsBody?.affectedByGravity = false
        ball.physicsBody?.allowsRotation = false
        ball.physicsBody?.usesPreciseCollisionDetection = true
        ball.physicsBody?.restitution = 1.0
        ball.physicsBody?.friction = 0.0
        ball.physicsBody?.linearDamping = 0.0
        ball.physicsBody?.angularDamping = 0.0
        ball.physicsBody?.categoryBitMask = 0x1
        ball.physicsBody?.collisionBitMask = 0x1
        ball.physicsBody?.contactTestBitMask = 0x1
        ball.name = "ball"
        
        worldNode.addChild(ball)
        
        // Setup Ball Trail Emitter
        createBallTrail()
    }
    
    func setupObstacles() {
        // Clean old obstacles
        for obs in obstacles {
            obs.removeFromParent()
        }
        obstacles.removeAll()
        
        guard let viewModel = viewModel, viewModel.gameMode == .neonStorm else { return }
        
        // Obstacle 1: Upper center spinning barrier
        let obsSize1 = CGSize(width: 20, height: 120)
        let obstacle1 = SKShapeNode(rectOf: obsSize1, cornerRadius: 6)
        obstacle1.position = CGPoint(x: size.width / 2, y: size.height / 2 + 120)
        styleNeonNode(obstacle1, color: .purple)
        obstacle1.physicsBody = SKPhysicsBody(rectangleOf: obsSize1)
        obstacle1.physicsBody?.isDynamic = false
        obstacle1.physicsBody?.restitution = 1.0
        obstacle1.physicsBody?.friction = 0.0
        obstacle1.physicsBody?.categoryBitMask = 0x1
        obstacle1.physicsBody?.collisionBitMask = 0x1
        obstacle1.name = "obstacle"
        worldNode.addChild(obstacle1)
        obstacles.append(obstacle1)
        
        // Obstacle 2: Lower center spinning barrier
        let obsSize2 = CGSize(width: 20, height: 120)
        let obstacle2 = SKShapeNode(rectOf: obsSize2, cornerRadius: 6)
        obstacle2.position = CGPoint(x: size.width / 2, y: size.height / 2 - 120)
        styleNeonNode(obstacle2, color: .purple)
        obstacle2.physicsBody = SKPhysicsBody(rectangleOf: obsSize2)
        obstacle2.physicsBody?.isDynamic = false
        obstacle2.physicsBody?.restitution = 1.0
        obstacle2.physicsBody?.friction = 0.0
        obstacle2.physicsBody?.categoryBitMask = 0x1
        obstacle2.physicsBody?.collisionBitMask = 0x1
        obstacle2.name = "obstacle"
        worldNode.addChild(obstacle2)
        obstacles.append(obstacle2)
        
        // Spin Actions
        let rotateCW = SKAction.repeatForever(SKAction.rotate(byAngle: .pi * 2, duration: 6.0))
        let rotateCCW = SKAction.repeatForever(SKAction.rotate(byAngle: -.pi * 2, duration: 6.0))
        
        obstacle1.run(rotateCW)
        obstacle2.run(rotateCCW)
    }
    
    // MARK: - Game Lifecycle Controls
    
    func startNewGame() {
        leftScore = 0
        rightScore = 0
        
        DispatchQueue.main.async {
            self.viewModel?.leftScore = 0
            self.viewModel?.rightScore = 0
            self.viewModel?.winnerName = ""
        }
        
        guard isInitialized else { return }
        
        updateSceneMode()
        setupObstacles()
        resetBall(serveToLeft: Bool.random())
    }
    
    func resetBall(serveToLeft: Bool) {
        ball.position = CGPoint(x: size.width / 2, y: size.height / 2)
        ball.physicsBody?.velocity = .zero
        
        guard let viewModel = viewModel else { return }
        
        // Put in countdown mode
        viewModel.countdownVal = 3
        viewModel.gameState = .countdown
        
        // Hiding cursor for focus during playing
        if viewModel.controlMode == .mouse && viewModel.isPlayerVsCPU {
            NSCursor.hide()
        }
        
        runCountdown(serveToLeft: serveToLeft)
    }
    
    private func runCountdown(serveToLeft: Bool) {
        let wait = SKAction.wait(forDuration: 0.65)
        let tick = SKAction.run { [weak self] in
            guard let self = self, let vm = self.viewModel else { return }
            vm.countdownVal -= 1
            if vm.countdownVal <= 0 {
                vm.gameState = .playing
                self.launchBall(serveToLeft: serveToLeft)
            } else {
                SoundSynth.shared.playBeep(frequency: 440, duration: 0.05, type: vm.soundType, volume: vm.soundVolume)
            }
        }
        
        let sequence = SKAction.sequence([
            SKAction.run { SoundSynth.shared.playBeep(frequency: 440, duration: 0.05, type: self.viewModel?.soundType ?? "sine", volume: self.viewModel?.soundVolume ?? 0.5) },
            wait, tick,
            wait, tick,
            wait, tick
        ])
        
        self.run(sequence)
    }
    
    private func launchBall(serveToLeft: Bool) {
        guard let viewModel = viewModel else { return }
        
        // Play launch sound
        SoundSynth.shared.playBeep(frequency: 880, duration: 0.1, type: viewModel.soundType, volume: viewModel.soundVolume)
        
        let speed = CGFloat(viewModel.ballSpeed)
        let angleLimit = 40.0 * CGFloat.pi / 180.0
        let angle = CGFloat.random(in: -angleLimit...angleLimit)
        
        let direction: CGFloat = serveToLeft ? -1.0 : 1.0
        let vx = direction * speed * cos(angle)
        let vy = speed * sin(angle)
        
        ball.physicsBody?.velocity = CGVector(dx: vx, dy: vy)
        
        // Show trail
        ballTrail?.isHidden = false
    }
    
    func pauseGame() {
        guard let viewModel = viewModel, viewModel.gameState == .playing else { return }
        viewModel.gameState = .paused
        savedVelocity = ball.physicsBody?.velocity ?? .zero
        ball.physicsBody?.velocity = .zero
        NSCursor.unhide()
    }
    
    func resumeGame() {
        guard let viewModel = viewModel, viewModel.gameState == .paused else { return }
        viewModel.gameState = .playing
        ball.physicsBody?.velocity = savedVelocity
        if viewModel.controlMode == .mouse && viewModel.isPlayerVsCPU {
            NSCursor.hide()
        }
    }
    
    // MARK: - Graphics Styling & Glow (HDR effect)
    
    private func styleNeonNode(_ node: SKShapeNode, color: NSColor) {
        node.fillColor = color.withAlphaComponent(0.85)
        node.strokeColor = color
        node.lineWidth = 2.0
        node.glowWidth = 4.0
    }
    
    func updateGlow() {
        guard let viewModel = viewModel else { return }
        let intensity = CGFloat(viewModel.glowIntensity)
        
        if intensity <= 0.05 {
            bloomNode.filter = nil
            bloomNode.shouldEnableEffects = false
        } else {
            let bloom = CIFilter(name: "CIBloom")!
            bloom.setValue(12.0 * intensity, forKey: "inputRadius")
            bloom.setValue(0.9 * intensity, forKey: "inputIntensity")
            bloomNode.filter = bloom
            bloomNode.shouldEnableEffects = true
        }
    }
    
    func updateSceneMode() {
        // Updates scene parameters like AI toggle and colors if modified
    }
    
    private func createBallTrail() {
        ballTrail?.removeFromParent()
        
        guard let texture = makeRadialTexture(size: CGSize(width: 16, height: 16), color: .yellow) else { return }
        
        let emitter = SKEmitterNode()
        emitter.particleTexture = texture
        emitter.particleBirthRate = 80
        emitter.particleLifetime = 0.35
        emitter.particlePositionRange = CGVector(dx: 2, dy: 2)
        emitter.particleSpeed = 0
        emitter.particleAlpha = 0.4
        emitter.particleAlphaSpeed = -1.15
        emitter.particleScale = 1.0
        emitter.particleScaleSpeed = -2.2
        emitter.particleBlendMode = .add
        
        // This is crucial: makes particles drift in scene coords rather than stick to the moving ball node!
        emitter.targetNode = self
        
        ball.addChild(emitter)
        ballTrail = emitter
        ballTrail?.isHidden = true // hide until launch
    }
    
    private func makeRadialTexture(size: CGSize, color: NSColor) -> SKTexture? {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        
        guard let context = NSGraphicsContext.current?.cgContext else { return nil }
        context.clear(CGRect(origin: .zero, size: size))
        
        let colors = [color.cgColor, color.withAlphaComponent(0.0).cgColor] as CFArray
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let locations: [CGFloat] = [0.0, 1.0]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else { return nil }
        
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size.width / 2, options: [])
        
        return SKTexture(image: image)
    }
    
    private func spawnSparks(at position: CGPoint, color: NSColor) {
        guard let texture = makeRadialTexture(size: CGSize(width: 10, height: 10), color: color) else { return }
        
        let emitter = SKEmitterNode()
        emitter.particleTexture = texture
        emitter.particleBirthRate = 0
        emitter.numParticlesToEmit = 24
        emitter.particleLifetime = 0.45
        emitter.particleLifetimeRange = 0.15
        emitter.particleSpeed = 160
        emitter.particleSpeedRange = 70
        emitter.emissionAngleRange = .pi * 2
        emitter.particleAlpha = 1.0
        emitter.particleAlphaSpeed = -2.2
        emitter.particleScale = 0.9
        emitter.particleScaleSpeed = -1.6
        emitter.particleBlendMode = .add
        emitter.position = position
        
        worldNode.addChild(emitter)
        
        let wait = SKAction.wait(forDuration: 0.8)
        let remove = SKAction.removeFromParent()
        emitter.run(SKAction.sequence([wait, remove]))
    }
    
    private func triggerShake(intensity: CGFloat) {
        guard let viewModel = viewModel else { return }
        shakeIntensity = intensity * CGFloat(viewModel.shakeMultiplier)
    }
    
    // MARK: - Game Loop & Updates
    
    override func update(_ currentTime: TimeInterval) {
        // Track FPS
        if lastUpdateTime == 0 {
            lastUpdateTime = currentTime
            return
        }
        let dt = currentTime - lastUpdateTime
        lastUpdateTime = currentTime
        
        frameCount += 1
        fpsTimer += dt
        if fpsTimer >= 1.0 {
            let currentFPS = Int(round(Double(frameCount) / fpsTimer))
            DispatchQueue.main.async {
                self.viewModel?.fps = currentFPS
            }
            frameCount = 0
            fpsTimer = 0
        }
        
        guard let viewModel = viewModel else { return }
        
        if viewModel.gameState == .playing {
            // Update Keyboard Paddle control
            updatePaddles(dt: dt)
            
            // Update CPU AI paddle control
            updateCPU(dt: dt)
            
            // Prevent ball horizontal lock (stuck bouncing exactly side to side with no vertical velocity)
            checkBallStuck()
            
            // Check out-of-bounds score conditions
            checkScore()
        }
        
        // Decay Screen Shake
        updateCameraShake()
    }
    
    private func updatePaddles(dt: TimeInterval) {
        let speed: CGFloat = 520.0 * CGFloat(dt)
        let minY: CGFloat = 70
        let maxY: CGFloat = size.height - 70
        
        // Left paddle (W/S) - if Keyboard mode selected
        if viewModel?.controlMode == .keyboard {
            if pressedKeys.contains(13) { // 'W' Key
                leftPaddle.position.y = min(maxY, leftPaddle.position.y + speed)
            }
            if pressedKeys.contains(1) { // 'S' Key
                leftPaddle.position.y = max(minY, leftPaddle.position.y - speed)
            }
        }
        
        // Right paddle (Up/Down Arrows) - if Player vs Player mode active
        if let vm = viewModel, !vm.isPlayerVsCPU {
            if pressedKeys.contains(126) { // Up Arrow
                rightPaddle.position.y = min(maxY, rightPaddle.position.y + speed)
            }
            if pressedKeys.contains(125) { // Down Arrow
                rightPaddle.position.y = max(minY, rightPaddle.position.y - speed)
            }
        }
    }
    
    private func updateCPU(dt: TimeInterval) {
        guard let viewModel = viewModel, viewModel.isPlayerVsCPU else { return }
        
        var aiMaxSpeed: CGFloat = 5.5
        var aiDeadZone: CGFloat = 12.0
        var idleBackToCenter = true
        
        switch viewModel.aiDifficulty {
        case .easy:
            aiMaxSpeed = 3.6
            aiDeadZone = 38.0
        case .medium:
            aiMaxSpeed = 6.2
            aiDeadZone = 14.0
        case .hard:
            aiMaxSpeed = 9.5
            aiDeadZone = 5.0
        case .impossible:
            aiMaxSpeed = 22.0
            aiDeadZone = 0.0
            idleBackToCenter = false
        }
        
        let targetY: CGFloat
        if let ballVelX = ball.physicsBody?.velocity.dx, ballVelX > 0 {
            // Ball is coming towards CPU paddle - track it
            targetY = ball.position.y
        } else {
            // Ball is moving away - drift slowly back to middle
            targetY = idleBackToCenter ? size.height / 2 : ball.position.y
        }
        
        let diff = targetY - rightPaddle.position.y
        if abs(diff) > aiDeadZone {
            let direction: CGFloat = diff > 0 ? 1.0 : -1.0
            // Lerp-like velocity smoothing close to target Y
            let moveRate = min(aiMaxSpeed, abs(diff) * 0.15)
            rightPaddle.position.y = max(70, min(size.height - 70, rightPaddle.position.y + direction * moveRate))
        }
    }
    
    private func checkBallStuck() {
        guard let velocity = ball.physicsBody?.velocity else { return }
        let speed = sqrt(velocity.dx * velocity.dx + velocity.dy * velocity.dy)
        
        // If ball is moving fast but has almost zero vertical motion, force a bounce angle
        if speed > 2.0 && abs(velocity.dy) < 0.6 {
            let randomForceY: CGFloat = Bool.random() ? 1.5 : -1.5
            ball.physicsBody?.velocity = CGVector(dx: velocity.dx, dy: randomForceY)
        }
    }
    
    private func checkScore() {
        let ballX = ball.position.x
        let boundaryMargin: CGFloat = 15.0
        
        if ballX < boundaryMargin {
            // Right Scores
            scoreGoal(leftScored: false)
        } else if ballX > size.width - boundaryMargin {
            // Left Scores
            scoreGoal(leftScored: true)
        }
    }
    
    private func scoreGoal(leftScored: Bool) {
        ballTrail?.isHidden = true
        ball.physicsBody?.velocity = .zero
        
        guard let viewModel = viewModel else { return }
        
        if leftScored {
            leftScore += 1
            viewModel.leftScore = leftScore
            SoundSynth.shared.playScoreSound(volume: viewModel.soundVolume, type: viewModel.soundType)
            triggerShake(intensity: 7.0)
            spawnSparks(at: ball.position, color: .yellow)
        } else {
            rightScore += 1
            viewModel.rightScore = rightScore
            SoundSynth.shared.playScoreSound(volume: viewModel.soundVolume, type: viewModel.soundType)
            triggerShake(intensity: 7.0)
            spawnSparks(at: ball.position, color: .yellow)
        }
        
        // Verify Win Condition (Skip win checks in Zen mode)
        if viewModel.gameMode != .zen && (leftScore >= winningScore || rightScore >= winningScore) {
            handleGameOver()
        } else {
            // Continue playing - serve ball to the loser
            resetBall(serveToLeft: leftScored)
        }
    }
    
    private func handleGameOver() {
        guard let viewModel = viewModel else { return }
        viewModel.gameState = .gameOver
        NSCursor.unhide()
        
        let leftWon = leftScore >= winningScore
        let winnerString: String
        
        if viewModel.isPlayerVsCPU {
            winnerString = leftWon ? "PLAYER WINS!" : "CPU WINS!"
        } else {
            winnerString = leftWon ? "PLAYER 1 WINS!" : "PLAYER 2 WINS!"
        }
        
        viewModel.winnerName = winnerString
        
        if leftWon && viewModel.isPlayerVsCPU {
            SoundSynth.shared.playWinSound(volume: viewModel.soundVolume, type: viewModel.soundType)
        } else if !leftWon && viewModel.isPlayerVsCPU {
            SoundSynth.shared.playLoseSound(volume: viewModel.soundVolume, type: viewModel.soundType)
        } else {
            SoundSynth.shared.playWinSound(volume: viewModel.soundVolume, type: viewModel.soundType)
        }
    }
    
    private func updateCameraShake() {
        if shakeIntensity > 0.05 {
            let dx = CGFloat.random(in: -shakeIntensity...shakeIntensity)
            let dy = CGFloat.random(in: -shakeIntensity...shakeIntensity)
            camera?.position = CGPoint(x: size.width / 2 + dx, y: size.height / 2 + dy)
            shakeIntensity *= 0.88 // exponential decay
        } else {
            camera?.position = CGPoint(x: size.width / 2, y: size.height / 2)
            shakeIntensity = 0
        }
    }
    
    // MARK: - Input Responder Events
    
    override func mouseMoved(with event: NSEvent) {
        guard let viewModel = viewModel,
              viewModel.gameState == .playing && viewModel.controlMode == .mouse && viewModel.isPlayerVsCPU else {
            return
        }
        
        // Map mouse Y coordinate directly to Left Paddle Y
        let location = event.location(in: self)
        let minY: CGFloat = 70
        let maxY: CGFloat = size.height - 70
        leftPaddle.position.y = max(minY, min(maxY, location.y))
    }
    
    override func mouseDown(with event: NSEvent) {
        // Clicking pauses/unpauses the game if playing
        guard let viewModel = viewModel else { return }
        if viewModel.gameState == .playing {
            pauseGame()
        } else if viewModel.gameState == .paused {
            resumeGame()
        }
    }
    
    override func keyDown(with event: NSEvent) {
        pressedKeys.insert(event.keyCode)
        
        // Handle Space Key (49) to pause/resume
        if event.keyCode == 49 {
            guard let viewModel = viewModel else { return }
            if viewModel.gameState == .playing {
                pauseGame()
            } else if viewModel.gameState == .paused {
                resumeGame()
            }
        }
        
        // Escape Key (53) returns to Menu
        if event.keyCode == 53 {
            guard let viewModel = viewModel else { return }
            viewModel.gameState = .menu
            ball.physicsBody?.velocity = .zero
            NSCursor.unhide()
        }
    }
    
    override func keyUp(with event: NSEvent) {
        pressedKeys.remove(event.keyCode)
    }
    
    // MARK: - Physics Collision Contact Delegate
    
    func didBegin(_ contact: SKPhysicsContact) {
        guard let viewModel = viewModel, viewModel.gameState == .playing else { return }
        
        let bodyA = contact.bodyA
        let bodyB = contact.bodyB
        
        // Resolve references to ball and collider node
        guard let ballNode = (bodyA.node?.name == "ball" ? bodyA.node : (bodyB.node?.name == "ball" ? bodyB.node : nil)) as? SKShapeNode,
              let collider = (bodyA.node?.name != "ball" ? bodyA.node : bodyB.node) else {
            return
        }
        
        if collider.name == "leftPaddle" || collider.name == "rightPaddle" {
            // Paddle Collisions
            let paddle = collider as! SKShapeNode
            let relativeY = (ballNode.position.y - paddle.position.y) / (100.0 / 2.0) // normalized offset: -1.0 to 1.0
            
            // Calculate current ball velocity length
            guard let velocity = ballNode.physicsBody?.velocity else { return }
            let currentSpeed = sqrt(velocity.dx * velocity.dx + velocity.dy * velocity.dy)
            
            // Accelerate slightly on each paddle bounce
            let nextSpeed = min(currentSpeed + CGFloat(viewModel.ballSpeedIncrement), CGFloat(viewModel.maxBallSpeed))
            
            // Bounce direction depends on which paddle was hit
            let dirX: CGFloat = paddle.name == "leftPaddle" ? 1.0 : -1.0
            
            // Calculate rebound angle (max 52 degrees deflection)
            let maxAngle = 52.0 * CGFloat.pi / 180.0
            let randomness = CGFloat(viewModel.bounceRandomness) * CGFloat.random(in: -2.5...2.5) * CGFloat.pi / 180.0
            let angle = (relativeY * maxAngle) + randomness
            
            let vx = dirX * nextSpeed * cos(angle)
            let vy = nextSpeed * sin(angle)
            
            ballNode.physicsBody?.velocity = CGVector(dx: vx, dy: vy)
            
            // Play collision synth sound - frequency modulates depending on where ball hits paddle (higher on outer tips)
            let pitchShift = abs(Float(relativeY)) * 180.0
            SoundSynth.shared.playBeep(
                frequency: 580.0 + pitchShift,
                duration: 0.08,
                type: viewModel.soundType,
                volume: viewModel.soundVolume
            )
            
            // Shake and Spark effects
            triggerShake(intensity: 5.5)
            spawnSparks(at: contact.contactPoint, color: paddle.name == "leftPaddle" ? .cyan : .magenta)
            
        } else if collider.name == "wall" {
            // Top/Bottom Wall Collisions
            SoundSynth.shared.playBeep(
                frequency: 380.0,
                duration: 0.06,
                type: viewModel.soundType,
                volume: viewModel.soundVolume
            )
            
            triggerShake(intensity: 2.2)
            spawnSparks(at: contact.contactPoint, color: .cyan)
            
        } else if collider.name == "obstacle" {
            // Dynamic Rotating Obstacle Collision (Neon Storm Mode)
            // Retrieve current ball velocity and add acceleration
            guard let velocity = ballNode.physicsBody?.velocity else { return }
            let currentSpeed = sqrt(velocity.dx * velocity.dx + velocity.dy * velocity.dy)
            let nextSpeed = min(currentSpeed + CGFloat(viewModel.ballSpeedIncrement * 0.5), CGFloat(viewModel.maxBallSpeed))
            
            // Add slight randomness to bounce off rotating obstacle
            let normalX = contact.contactNormal.dx
            let normalY = contact.contactNormal.dy
            
            // Standard bounce formula: v_out = v_in - 2 * (v_in . normal) * normal
            let dot = velocity.dx * normalX + velocity.dy * normalY
            var rx = velocity.dx - 2.0 * dot * normalX
            var ry = velocity.dy - 2.0 * dot * normalY
            
            // Normalize and scale to speed
            let rSpeed = sqrt(rx * rx + ry * ry)
            if rSpeed > 0 {
                rx = (rx / rSpeed) * nextSpeed
                ry = (ry / rSpeed) * nextSpeed
            }
            
            ballNode.physicsBody?.velocity = CGVector(dx: rx, dy: ry)
            
            SoundSynth.shared.playBeep(
                frequency: 480.0,
                duration: 0.09,
                type: viewModel.soundType,
                volume: viewModel.soundVolume
            )
            
            triggerShake(intensity: 4.5)
            spawnSparks(at: contact.contactPoint, color: .purple)
        }
    }
}

// MARK: - SpriteKit macOS View Wrapper

struct PingPongSpriteView: NSViewRepresentable {
    @ObservedObject var viewModel: GameViewModel
    let scene: GameScene
    
    func makeNSView(context: Context) -> SKView {
        let skView = SKView()
        skView.ignoresSiblingOrder = true
        skView.preferredFramesPerSecond = 120
        
        scene.viewModel = viewModel
        scene.size = CGSize(width: 1024, height: 768)
        scene.scaleMode = .aspectFit
        
        skView.presentScene(scene)
        
        // Trigger key bindings and window active focus inside scene
        DispatchQueue.main.async {
            skView.window?.makeFirstResponder(scene)
            
            // Create mouse tracking area
            let trackingArea = NSTrackingArea(
                rect: skView.bounds,
                options: [.activeAlways, .mouseMoved, .inVisibleRect],
                owner: scene,
                userInfo: nil
            )
            skView.addTrackingArea(trackingArea)
        }
        
        return skView
    }
    
    func updateNSView(_ nsView: SKView, context: Context) {
        // Propagate sliders/settings updates to scene dynamically
        scene.updateGlow()
        scene.updateSceneMode()
    }
}

// MARK: - SwiftUI User Interface Components

struct GlassmorphicContainer<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.5), radius: 10, x: 0, y: 10)
    }
}

struct NeoButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(isHovering ? 0.35 : 0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(color.opacity(isHovering ? 1.0 : 0.6), lineWidth: 2)
                        )
                )
                .scaleEffect(isHovering ? 1.02 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHovering)
                .shadow(color: color.opacity(isHovering ? 0.6 : 0.0), radius: 12)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

struct MenuView: View {
    @ObservedObject var viewModel: GameViewModel
    let onStart: () -> Void
    
    @State private var isSettingsExpanded = false
    @State private var titlePulse = false
    
    var body: some View {
        VStack(spacing: 35) {
            // Neon Header
            VStack(spacing: 8) {
                Text("NEON PING PONG")
                    .font(.system(size: 54, weight: .black, design: .monospaced))
                    .tracking(6)
                    .foregroundColor(.yellow)
                    .shadow(color: Color.yellow.opacity(titlePulse ? 0.95 : 0.5), radius: titlePulse ? 20 : 10)
                    .scaleEffect(titlePulse ? 1.01 : 0.99)
                    .animation(Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: titlePulse)
                    .onAppear {
                        titlePulse = true
                    }
                
                Text("APPLE SILICON M3 EDITION")
                    .font(.system(.caption, design: .monospaced))
                    .tracking(4)
                    .foregroundColor(.cyan)
                    .opacity(0.85)
            }
            
            HStack(alignment: .top, spacing: 30) {
                // Game Mode Card
                GlassmorphicContainer {
                    VStack(spacing: 20) {
                        Text("GAME SETUP")
                            .font(.system(.headline, design: .monospaced))
                            .foregroundColor(.white)
                            .tracking(2)
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        // Opponent Toggle
                        VStack(alignment: .leading, spacing: 8) {
                            Text("OPPONENT")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.gray)
                            
                            Picker("Opponent", selection: $viewModel.isPlayerVsCPU) {
                                Text("VS COMPUTER").tag(true)
                                Text("LOCAL 2 PLAYERS").tag(false)
                            }
                            .pickerStyle(.segmented)
                        }
                        
                        // AI Difficulty
                        if viewModel.isPlayerVsCPU {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("CPU DIFFICULTY")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.gray)
                                
                                Picker("Difficulty", selection: $viewModel.aiDifficulty) {
                                    ForEach(AIDifficulty.allCases) { diff in
                                        Text(diff.rawValue.uppercased()).tag(diff)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        
                        // Game Mode Selection
                        VStack(alignment: .leading, spacing: 8) {
                            Text("GAME MODE")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.gray)
                            
                            Picker("Mode", selection: $viewModel.gameMode) {
                                ForEach(GameMode.allCases) { mode in
                                    Text(mode.rawValue.uppercased()).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        
                        // Paddle Control Mode
                        if viewModel.isPlayerVsCPU {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("YOUR CONTROL")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.gray)
                                
                                Picker("Control", selection: $viewModel.controlMode) {
                                    ForEach(ControlMode.allCases) { ctrl in
                                        Text(ctrl.rawValue.uppercased()).tag(ctrl)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        
                        Spacer().frame(height: 10)
                        
                        NeoButton(title: "LAUNCH GAME", color: .cyan, action: onStart)
                    }
                    .frame(width: 320)
                }
                
                // Advanced Controls Drawer
                VStack(spacing: 15) {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isSettingsExpanded.toggle()
                        }
                    }) {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                            Text(isSettingsExpanded ? "HIDE DEV PANEL" : "SHOW DEV PANEL")
                                .font(.system(.callout, design: .monospaced))
                            Image(systemName: isSettingsExpanded ? "chevron.up" : "chevron.down")
                        }
                        .foregroundColor(.gray)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    
                    if isSettingsExpanded {
                        GlassmorphicContainer {
                            VStack(spacing: 16) {
                                Text("DEV SETTINGS")
                                    .font(.system(.headline, design: .monospaced))
                                    .foregroundColor(.white)
                                    .tracking(2)
                                
                                Divider().background(Color.white.opacity(0.1))
                                
                                DeveloperSliders(viewModel: viewModel)
                            }
                            .frame(width: 340)
                        }
                        .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
                    }
                }
            }
            
            // Footer Control Legends
            VStack(spacing: 6) {
                Text("CONTROLS")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.gray)
                    .fontWeight(.bold)
                
                HStack(spacing: 30) {
                    Text("P1: W/S Keys (or Mouse)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.cyan)
                    Text("P2: Up/Down Arrows")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.magenta)
                    Text("Space: Pause Game")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.yellow)
                    Text("Esc: Return to Menu")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.purple)
                }
                .opacity(0.7)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Color.black
                
                // Tech glowing meshes background
                RadialGradient(gradient: Gradient(colors: [Color.cyan.opacity(0.08), Color.clear]), center: .topLeading, startRadius: 0, endRadius: 600)
                RadialGradient(gradient: Gradient(colors: [Color.magenta.opacity(0.08), Color.clear]), center: .bottomTrailing, startRadius: 0, endRadius: 600)
            }
        )
    }
}

struct DeveloperSliders: View {
    @ObservedObject var viewModel: GameViewModel
    
    var body: some View {
        VStack(spacing: 14) {
            // Glow Slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("HDR Glow Intensity")
                    Spacer()
                    Text(String(format: "%.1fx", viewModel.glowIntensity)).foregroundColor(.cyan)
                }
                .font(.system(.caption, design: .monospaced))
                
                Slider(value: $viewModel.glowIntensity, in: 0.0...2.5, step: 0.1)
                    .accentColor(.cyan)
            }
            
            // Screen Shake Slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Impact Screen Shake")
                    Spacer()
                    Text(String(format: "%.1fx", viewModel.shakeMultiplier)).foregroundColor(.cyan)
                }
                .font(.system(.caption, design: .monospaced))
                
                Slider(value: $viewModel.shakeMultiplier, in: 0.0...2.0, step: 0.1)
                    .accentColor(.cyan)
            }
            
            // Initial Speed Slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Ball Launch Speed")
                    Spacer()
                    Text(String(format: "%.0f px/f", viewModel.ballSpeed)).foregroundColor(.cyan)
                }
                .font(.system(.caption, design: .monospaced))
                
                Slider(value: $viewModel.ballSpeed, in: 4.0...15.0, step: 0.5)
                    .accentColor(.cyan)
            }
            
            // Max Speed Slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max Ball Speed")
                    Spacer()
                    Text(String(format: "%.0f px/f", viewModel.maxBallSpeed)).foregroundColor(.cyan)
                }
                .font(.system(.caption, design: .monospaced))
                
                Slider(value: $viewModel.maxBallSpeed, in: 12.0...35.0, step: 1.0)
                    .accentColor(.cyan)
            }
            
            // Sound type picker
            VStack(alignment: .leading, spacing: 4) {
                Text("SYNTH WAVEFORM")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.gray)
                
                Picker("Sound Synth", selection: $viewModel.soundType) {
                    Text("SINE").tag("sine")
                    Text("SQUARE").tag("square")
                    Text("TRIANGLE").tag("triangle")
                    Text("MUTED").tag("off")
                }
                .pickerStyle(.segmented)
            }
            
            // Sound volume slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Synth Volume")
                    Spacer()
                    Text(String(format: "%.0f%%", viewModel.soundVolume * 100)).foregroundColor(.cyan)
                }
                .font(.system(.caption, design: .monospaced))
                
                Slider(value: $viewModel.soundVolume, in: 0.0...1.0, step: 0.05)
                    .accentColor(.cyan)
            }
        }
    }
}

struct ScoreboardView: View {
    @ObservedObject var viewModel: GameViewModel
    let onPauseToggle: () -> Void
    
    var body: some View {
        HStack {
            // Player 1
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.isPlayerVsCPU ? "PLAYER" : "PLAYER 1")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.cyan)
                Text("\(viewModel.leftScore)")
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
            }
            
            Spacer()
            
            // Mid HUD Details
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(viewModel.gameMode.rawValue.uppercased())
                    Text("•")
                    Text(viewModel.isPlayerVsCPU ? "CPU \(viewModel.aiDifficulty.rawValue.uppercased())" : "PVP")
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.yellow)
                
                HStack(spacing: 12) {
                    Text("\(viewModel.fps) FPS")
                    Text("•")
                    Button(action: onPauseToggle) {
                        Text(viewModel.gameState == .paused ? "RESUME" : "PAUSE")
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.gray)
            }
            
            Spacer()
            
            // Player 2 / CPU
            VStack(alignment: .trailing, spacing: 4) {
                Text(viewModel.isPlayerVsCPU ? "COMPUTER" : "PLAYER 2")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.magenta)
                Text("\(viewModel.rightScore)")
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .foregroundColor(.magenta)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding(.top, 20)
        .padding(.horizontal, 40)
    }
}

struct CountdownView: View {
    let value: Int
    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 0.0
    
    var body: some View {
        Text("\(value)")
            .font(.system(size: 96, weight: .black, design: .monospaced))
            .foregroundColor(.yellow)
            .shadow(color: .yellow, radius: 15)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                scale = 0.5
                opacity = 0.0
                withAnimation(.easeOut(duration: 0.15)) {
                    scale = 1.2
                    opacity = 1.0
                }
                withAnimation(.easeIn(duration: 0.45).delay(0.2)) {
                    scale = 1.8
                    opacity = 0.0
                }
            }
            .id(value) // Triggers animation on value change
    }
}

struct GameOverlayView: View {
    @ObservedObject var viewModel: GameViewModel
    let onResume: () -> Void
    let onExit: () -> Void
    
    var body: some View {
        ZStack {
            if viewModel.gameState == .paused {
                Color.black.opacity(0.65)
                    .edgesIgnoringSafeArea(.all)
                
                GlassmorphicContainer {
                    VStack(spacing: 24) {
                        Text("GAME PAUSED")
                            .font(.system(.title2, design: .monospaced))
                            .fontWeight(.bold)
                            .foregroundColor(.yellow)
                            .shadow(color: .yellow, radius: 8)
                        
                        Text("Click screen or press SPACE to resume\nPress ESC to exit to main menu")
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.gray)
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        HStack(spacing: 20) {
                            Button(action: onResume) {
                                Text("RESUME")
                                    .font(.system(.headline, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 24)
                                    .background(RoundedRectangle(cornerRadius: 8).stroke(Color.cyan, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: onExit) {
                                Text("QUIT TO MENU")
                                    .font(.system(.headline, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 24)
                                    .background(RoundedRectangle(cornerRadius: 8).stroke(Color.magenta, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .frame(width: 420)
                }
            }
            
            if viewModel.gameState == .countdown {
                CountdownView(value: viewModel.countdownVal)
            }
        }
    }
}

struct GameOverView: View {
    @ObservedObject var viewModel: GameViewModel
    let onPlayAgain: () -> Void
    let onExit: () -> Void
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .edgesIgnoringSafeArea(.all)
            
            GlassmorphicContainer {
                VStack(spacing: 28) {
                    Text("GAME OVER")
                        .font(.system(size: 42, weight: .black, design: .monospaced))
                        .foregroundColor(.yellow)
                        .shadow(color: .yellow, radius: 15)
                    
                    Text(viewModel.winnerName)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(viewModel.winnerName.contains("PLAYER") ? .cyan : .magenta)
                        .shadow(color: viewModel.winnerName.contains("PLAYER") ? .cyan : .magenta, radius: 12)
                    
                    Text("Scoreboard final: \(viewModel.leftScore) - \(viewModel.rightScore)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.gray)
                    
                    Divider().background(Color.white.opacity(0.1))
                    
                    HStack(spacing: 24) {
                        Button(action: onPlayAgain) {
                            Text("PLAY AGAIN")
                                .font(.system(.headline, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.cyan.opacity(0.2))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cyan, lineWidth: 2))
                                )
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: onExit) {
                            Text("MAIN MENU")
                                .font(.system(.headline, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.magenta.opacity(0.2))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.magenta, lineWidth: 2))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(15)
                .frame(width: 480)
            }
        }
    }
}

struct GameView: View {
    @ObservedObject var viewModel: GameViewModel
    let scene: GameScene
    let onExit: () -> Void
    
    var body: some View {
        ZStack(alignment: .top) {
            // SpriteKit viewport
            PingPongSpriteView(viewModel: viewModel, scene: scene)
                .frame(width: 1024, height: 768)
                .background(Color.black)
            
            // HUD Scores
            ScoreboardView(viewModel: viewModel, onPauseToggle: {
                if viewModel.gameState == .playing {
                    scene.pauseGame()
                } else if viewModel.gameState == .paused {
                    scene.resumeGame()
                }
            })
            
            // Game Countdown/Pause overlays
            GameOverlayView(viewModel: viewModel, onResume: {
                scene.resumeGame()
            }, onExit: onExit)
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = GameViewModel()
    
    // Instantiate scene once to persist it across menu <-> gameplay views
    @State private var scene = GameScene()
    
    var body: some View {
        ZStack {
            switch viewModel.gameState {
            case .menu:
                MenuView(viewModel: viewModel, onStart: {
                    viewModel.gameState = .countdown
                    scene.startNewGame()
                })
            case .playing, .countdown, .paused:
                GameView(viewModel: viewModel, scene: scene, onExit: {
                    viewModel.gameState = .menu
                })
            case .gameOver:
                GameOverView(viewModel: viewModel, onPlayAgain: {
                    viewModel.gameState = .countdown
                    scene.startNewGame()
                }, onExit: {
                    viewModel.gameState = .menu
                })
            }
        }
        .frame(width: 1024, height: 768)
        .background(Color.black)
        .onChange(of: viewModel.glowIntensity) {
            scene.updateGlow()
        }
    }
}

// MARK: - App Entry Point

@main
struct PingPongApp: App {
    init() {
        if CommandLine.arguments.contains("--test") {
            runHeadlessTests()
            exit(0)
        }
        // AppKit initialization to force App registration in active foreground UI pool when compiled as raw command line binary
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    var body: some Scene {
        Window("Neon Ping Pong", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

// MARK: - Headless Test Runner

func runHeadlessTests() {
    print("=========================================")
    print("🧪 Running Neon Ping Pong Headless Tests...")
    print("=========================================")
    
    // Test 1: SoundSynth Test
    print("Testing SoundSynth...")
    let synth = SoundSynth.shared
    synth.playBeep(frequency: 440.0, duration: 0.01, type: "sine", volume: 0.1)
    print("[✓] SoundSynth Initialized and tone scheduled.")
    
    // Test 2: GameScene Initialization
    print("Testing GameScene Setup...")
    let scene = GameScene(size: CGSize(width: 1024, height: 768))
    let mockView = SKView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
    scene.didMove(to: mockView)
    
    guard scene.childNode(withName: "//ball") != nil else {
        print("[✗] Failed: Ball node not found.")
        exit(1)
    }
    guard scene.childNode(withName: "//leftPaddle") != nil else {
        print("[✗] Failed: Left paddle node not found.")
        exit(1)
    }
    guard scene.childNode(withName: "//rightPaddle") != nil else {
        print("[✗] Failed: Right paddle node not found.")
        exit(1)
    }
    print("[✓] GameScene components successfully instantiated.")
    
    // Test 3: Ball Reset and Launch Logic
    print("Testing Ball Physics & Launch...")
    let vm = GameViewModel()
    scene.viewModel = vm
    scene.startNewGame()
    
    let ballNode = scene.childNode(withName: "//ball") as! SKShapeNode
    if ballNode.position.x != 512 || ballNode.position.y != 384 {
        print("[✗] Failed: Ball position not reset to center.")
        exit(1)
    }
    print("[✓] Ball position reset logic verified.")
    
    // Test 4: AI Logic Simulation
    print("Testing CPU AI Tracking...")
    let rightPaddle = scene.childNode(withName: "//rightPaddle") as! SKShapeNode
    let initialY = rightPaddle.position.y
    
    ballNode.position = CGPoint(x: 800, y: 600)
    ballNode.physicsBody?.velocity = CGVector(dx: 10, dy: 0) // moving right towards CPU
    
    vm.gameState = .playing
    scene.update(0.1) // Initializes lastUpdateTime
    scene.update(0.2) // Runs update loop
    
    let updatedY = rightPaddle.position.y
    if updatedY <= initialY {
        print("[✗] Failed: CPU paddle did not move up to track the high ball. (Y went from \(initialY) to \(updatedY))")
        exit(1)
    }
    print("[✓] CPU AI tracked ball successfully (Y: \(initialY) -> \(updatedY)).")
    
    // Test 5: Scoring System
    print("Testing Out-Of-Bounds Scoring...")
    vm.gameState = .playing
    ballNode.position = CGPoint(x: -5, y: 384)
    scene.update(0.3) // Runs update loop with next timestamp
    print("[✓] Score check processed successfully.")
    
    print("\n🎉 ALL HEADLESS TESTS COMPLETED SUCCESSFULLY!")
    print("=========================================")
}
