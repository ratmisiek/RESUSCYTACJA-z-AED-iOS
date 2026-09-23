import UIKit
import WebKit
import CoreLocation
import AVFoundation

@MainActor
final class MainViewController: UIViewController, WKNavigationDelegate, CLLocationManagerDelegate, WKScriptMessageHandler, AVSpeechSynthesizerDelegate {
    private var webView: WKWebView!
    private let locationManager = CLLocationManager()
    private let speech = AVSpeechSynthesizer()
    private var metro30: AVAudioPlayer?
    private var metro15: AVAudioPlayer?
    private var metroRatio = 30
    private var pendingSpeech: String?
    private var metronomeWasRunningBeforeInterruption = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        UIApplication.shared.isIdleTimerDisabled = true

        locationManager.delegate = self
        speech.delegate = self
        configureAudio()
        configureAudioNotifications()
        configureWebView()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    deinit {
        UIApplication.shared.isIdleTimerDisabled = false
        stopMetronome()
        locationManager.stopUpdatingLocation()
    }

    // MARK: WebView
    private func configureWebView() {
        let controller = WKUserContentController()
        controller.add(self, name: "iosBridge")

        let bridgeJS = """
        window.AndroidBridge = {
          setMetronomeRatio: function(r){ window.webkit.messageHandlers.iosBridge.postMessage({action:'setMetronomeRatio', ratio:Number(r)}); },
          startMetronome: function(){ window.webkit.messageHandlers.iosBridge.postMessage({action:'startMetronome'}); },
          stopMetronome: function(){ window.webkit.messageHandlers.iosBridge.postMessage({action:'stopMetronome'}); },
          resetMetronomeCycle: function(){ window.webkit.messageHandlers.iosBridge.postMessage({action:'resetMetronomeCycle'}); },
          metronomeClick: function(kind){},
          speak: function(text){ window.webkit.messageHandlers.iosBridge.postMessage({action:'speak', text:String(text||'')}); },
          stopSpeech: function(){ window.webkit.messageHandlers.iosBridge.postMessage({action:'stopSpeech'}); },
          openTtsSettings: function(){ window.webkit.messageHandlers.iosBridge.postMessage({action:'openTtsSettings'}); },
          requestLocation: function(){ window.webkit.messageHandlers.iosBridge.postMessage({action:'requestLocation'}); },
          requestLocationPermission: function(){ window.webkit.messageHandlers.iosBridge.postMessage({action:'requestLocation'}); },
          navigateToAED: function(lat,lon){ window.webkit.messageHandlers.iosBridge.postMessage({action:'navigateToAED',lat:Number(lat),lon:Number(lon)}); },
          openMaps: function(url){ window.webkit.messageHandlers.iosBridge.postMessage({action:'openMaps',url:String(url||'')}); },
          closeApp: function(){ window.webkit.messageHandlers.iosBridge.postMessage({action:'closeApp'}); },
          isTtsReady: function(){ return true; },
          ttsStatus: function(){ return 'OK'; },
          testTTS: function(){ window.webkit.messageHandlers.iosBridge.postMessage({action:'speak',text:'To jest test lektora aplikacji RESUSCYTACJA z AED.'}); }
        };
        """
        controller.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    // MARK: JS bridge
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "iosBridge", let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "setMetronomeRatio":
            let ratio = (body["ratio"] as? NSNumber)?.intValue == 15 ? 15 : 30
            metroRatio = ratio
            if metro30?.isPlaying == true || metro15?.isPlaying == true { resetMetronome() }
        case "startMetronome": startMetronome()
        case "stopMetronome": stopMetronome()
        case "resetMetronomeCycle": resetMetronome()
        case "speak": speak(body["text"] as? String ?? "")
        case "stopSpeech": speech.stopSpeaking(at: .immediate)
        case "requestLocation": requestLocation()
        case "navigateToAED":
            if let lat = (body["lat"] as? NSNumber)?.doubleValue, let lon = (body["lon"] as? NSNumber)?.doubleValue {
                openAEDNavigation(lat: lat, lon: lon)
            }
        case "openMaps":
            if let url = body["url"] as? String { openURL(url) }
        case "closeApp":
            // iOS nie pozwala aplikacji programowo zakończyć własnego procesu.
            showIOSExitMessage()
        case "openTtsSettings":
            // iOS systemowy głos polski jest obsługiwany przez AVSpeechSynthesizer.
            break
        default: break
        }
    }

    // MARK: Speech
    private func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "pl-PL")
        // Android uses a normal, calm speaking rate. Keep iOS close to it.
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        speech.stopSpeaking(at: .immediate)
        // Re-activate the shared audio session so the metronome remains audible
        // while the system voice is speaking.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .allowBluetooth, .allowAirPlay])
            try session.setActive(true, options: [])
        } catch {}
        speech.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Keep the audio session ready for the CPR metronome after narration.
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
    }

    // MARK: Metronome
    private func configureAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .allowBluetooth, .allowAirPlay])
            try session.setActive(true, options: [])
            metro30 = try makeMetronomePlayer(beats: 30)
            metro15 = try makeMetronomePlayer(beats: 15)
            metro30?.numberOfLoops = -1
            metro15?.numberOfLoops = -1
            metro30?.prepareToPlay()
            metro15?.prepareToPlay()
        } catch {
            metro30 = nil
            metro15 = nil
        }
    }

    private func makeMetronomePlayer(beats: Int) throws -> AVAudioPlayer {
        let sampleRate = 44_100.0
        let samplesPerBeat = Int(round(sampleRate * 60.0 / 110.0))
        let totalSamples = samplesPerBeat * beats
        var pcm = [Int16](repeating: 0, count: totalSamples)
        for b in 0..<beats {
            let freq = b == beats - 1 ? 1320.0 : (b >= max(0, beats - 5) ? 1040.0 : 880.0)
            let amp = b == beats - 1 ? 0.95 : (b >= max(0, beats - 5) ? 0.82 : 0.70)
            let toneSamples = min(Int(round(sampleRate * (b == beats - 1 ? 0.090 : 0.065))), samplesPerBeat - 1)
            let start = b * samplesPerBeat
            let attack = max(1, Int(round(sampleRate * 0.004)))
            let release = max(1, Int(round(sampleRate * 0.014)))
            for i in 0..<toneSamples {
                let env: Double
                if i < attack { env = Double(i) / Double(attack) }
                else if i > toneSamples - release { env = Double(toneSamples - i) / Double(release) }
                else { env = 1.0 }
                let wave = sin(2.0 * Double.pi * freq * Double(i) / sampleRate)
                let value = Int(max(-32768, min(32767, round(wave * 32767.0 * amp * env))))
                pcm[start + i] = Int16(value)
            }
        }
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        var fileSize = UInt32(36 + pcm.count * 2).littleEndian
        data.append(Data(bytes: &fileSize, count: 4))
        data.append(contentsOf: "WAVEfmt ".utf8)
        var fmtSize = UInt32(16).littleEndian; data.append(Data(bytes: &fmtSize, count: 4))
        var audioFormat = UInt16(1).littleEndian; data.append(Data(bytes: &audioFormat, count: 2))
        var channels = UInt16(1).littleEndian; data.append(Data(bytes: &channels, count: 2))
        var sr = UInt32(44_100).littleEndian; data.append(Data(bytes: &sr, count: 4))
        var byteRate = UInt32(44_100 * 2).littleEndian; data.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(2).littleEndian; data.append(Data(bytes: &blockAlign, count: 2))
        var bits = UInt16(16).littleEndian; data.append(Data(bytes: &bits, count: 2))
        data.append(contentsOf: "data".utf8)
        var dataSize = UInt32(pcm.count * 2).littleEndian; data.append(Data(bytes: &dataSize, count: 4))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
    }

    private func startMetronome() {
        guard let player = metroRatio == 15 ? metro15 : metro30 else { return }
        metro30?.stop(); metro15?.stop()
        player.currentTime = 0
        player.play()
    }

    private func stopMetronome() {
        metro30?.stop(); metro15?.stop()
    }

    private func resetMetronome() {
        guard metro30?.isPlaying == true || metro15?.isPlaying == true else { return }
        startMetronome()
    }

    // Keep audio routing predictable on iPhone (speaker/Bluetooth) and stop
    // gracefully during a phone call or another system audio interruption.
    private func configureAudioNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            guard let info = note.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            if type == .began {
                self.metronomeWasRunningBeforeInterruption = self.metro30?.isPlaying == true || self.metro15?.isPlaying == true
                self.stopMetronome()
            } else {
                try? AVAudioSession.sharedInstance().setActive(true, options: [])
                if self.metronomeWasRunningBeforeInterruption {
                    self.metronomeWasRunningBeforeInterruption = false
                    self.startMetronome()
                }
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            try? AVAudioSession.sharedInstance().setActive(true, options: [])
        }
    }

    // MARK: Location
    private func requestLocation() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        switch CLLocationManager.authorizationStatus() {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.requestLocation()
        case .denied, .restricted:
            sendJS("window.nativeLocationError && window.nativeLocationError('Brak zgody na lokalizację telefonu. Włącz dostęp do lokalizacji w Ustawieniach.')")
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        @unknown default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = kCLDistanceFilterNone
            manager.requestLocation()
            sendJS("window.nativeLocationPermissionGranted && window.nativeLocationPermissionGranted()")
        case .denied, .restricted:
            sendJS("window.nativeLocationPermissionDenied && window.nativeLocationPermissionDenied()")
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        sendJS("window.setNativeLocation && window.setNativeLocation(\(loc.coordinate.latitude),\(loc.coordinate.longitude),\(loc.horizontalAccuracy))")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        sendJS("window.nativeLocationError && window.nativeLocationError('Nie udało się pobrać lokalizacji telefonu.')")
    }

    private func sendJS(_ javascript: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(javascript)
        }
    }

    // MARK: Navigation
    private func openAEDNavigation(lat: Double, lon: Double) {
        // 1) Prefer Google Maps when it is installed.
        if let google = URL(string: "comgooglemaps://?daddr=\(lat),\(lon)&directionsmode=walking"),
           UIApplication.shared.canOpenURL(google) {
            UIApplication.shared.open(google)
            return
        }
        // 2) Native Apple Maps is always available on iPhone.
        if let apple = URL(string: "http://maps.apple.com/?daddr=\(lat),\(lon)&dirflg=w") {
            UIApplication.shared.open(apple)
            return
        }
        // 3) Last resort: browser.
        if let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(lat),\(lon)&travelmode=walking") {
            UIApplication.shared.open(web)
        }
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        UIApplication.shared.open(url)
    }

    private func showIOSExitMessage() {
        let alert = UIAlertController(title: "RESUSCYTACJA z AED", message: "Na iPhonie aplikacji nie można zamknąć programowo. Możesz wyjść z niej gestem systemowym lub przyciskiem Home.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Links / permissions
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "tel" || scheme == "comgooglemaps" || scheme == "maps" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if let host = url.host?.lowercased(), host.contains("google.com"), url.path.lowercased().contains("/maps") {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
