import Cocoa
import CoreLocation
import Network
import OSLog

// MARK: - Main Application Structure

// Using proper @main attribute to specify entry point
@main
struct LocationAgentMain {
    static func main() {
        // Initialize the application
        let app = NSApplication.shared
        let delegate = LocationAgentAppHeadless()
        app.delegate = delegate
        app.run()
    }
}

// MARK: - Application Delegate

class LocationAgentAppHeadless: NSObject, NSApplicationDelegate {
    private let locationServer = LocationServer()
    private let logger = Logger(subsystem: "com.example.LocationAgent", category: "Application")
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the activation policy to accessory (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Start the location server immediately
        self.locationServer.start()
        
        // Log startup
        logger.info("Location Agent started - server running on port \(self.locationServer.port)")
        print("Location Agent started - server running on port \(self.locationServer.port)")
        
        // Schedule a repeating status update
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let location = self.locationServer.currentLocation {
                print("Location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            } else {
                print("Waiting for location data...")
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Stop the server
        self.locationServer.stop()
        logger.info("Location Agent terminated")
        print("Location Agent terminated")
    }
    
    // Process incoming SIGTERM signals for clean shutdown
    override init() {
        super.init()
        
        // Set up signal handling for clean termination
        signal(SIGTERM) { _ in
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - Location Server

class LocationServer: NSObject, CLLocationManagerDelegate {
    // Location components
    private let locationManager = CLLocationManager()
    private(set) var currentLocation: CLLocation?
    
    // HTTP server components
    private var listener: NWListener?
    let port: UInt16 = 8080
    
    // Logger
    private let logger = Logger(subsystem: "com.example.LocationAgent", category: "Server")
    
    override init() {
        super.init()
        
        // Configure location manager
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }
    
    // Start the server and location services
    func start() {
        // Request location permissions
        locationManager.requestAlwaysAuthorization()
        
        // Start location updates
        locationManager.startUpdatingLocation()
        
        // Create and start the HTTP server
        do {
            // Use TCP protocol
            let parameters = NWParameters.tcp
            
            // Create the listener on the specified port
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            // Set the state update handler
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                
                switch state {
                case .ready:
                    self.logger.info("Server is running and ready on port \(self.port)")
                    print("Server is running and ready on port \(self.port)")
                case .failed(let error):
                    self.logger.error("Server failed with error: \(error.localizedDescription)")
                    print("Server failed with error: \(error.localizedDescription)")
                    self.stop()
                    // Try to restart after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        self.start()
                    }
                case .setup:
                    self.logger.info("Server is setting up...")
                default:
                    break
                }
            }
            
            // Set up the connection handler
            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleConnection(newConnection)
            }
            
            // Start the listener
            listener?.start(queue: .main)
            
        } catch {
            logger.error("Failed to create server: \(error.localizedDescription)")
            print("Failed to create server: \(error.localizedDescription)")
        }
    }
    
    // Stop the server
    func stop() {
        listener?.cancel()
        locationManager.stopUpdatingLocation()
        logger.info("Server stopped")
    }
    
    // Handle incoming HTTP connections
    private func handleConnection(_ connection: NWConnection) {
        // Set up to receive the HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                self.logger.error("Error receiving data: \(error.localizedDescription)")
                return
            }
            
            // Send the response with location data
            self.sendResponse(connection)
        }
        
        // Start the connection
        connection.start(queue: .main)
    }
    
    // Send HTTP response with location data
    private func sendResponse(_ connection: NWConnection) {
        var responseString = ""
        
        if let location = currentLocation {
            // Format the location data for the response
            responseString = """
            HTTP/1.1 200 OK
            Content-Type: application/json
            Connection: close
            
            {
                "latitude": \(location.coordinate.latitude),
                "longitude": \(location.coordinate.longitude),
                "altitude": \(location.altitude),
                "horizontalAccuracy": \(location.horizontalAccuracy),
                "timestamp": "\(location.timestamp)"
            }
            """
            
            logger.debug("Sending location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
        } else {
            // If location data isn't available yet
            responseString = """
            HTTP/1.1 200 OK
            Content-Type: text/plain
            Connection: close
            
            Location data is not yet available. Please try again in a moment.
            """
            
            logger.debug("Sending location not available message")
        }
        
        // Replace regular newlines with CRLF (carriage return + line feed)
        responseString = responseString.replacingOccurrences(of: "\n", with: "\r\n")
        
        // Convert to Data and send
        let responseData = responseString.data(using: .utf8)!
        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error = error {
                self.logger.error("Error sending response: \(error.localizedDescription)")
            }
            
            // Close the connection after sending
            connection.cancel()
        })
    }
    
    // MARK: - CLLocationManagerDelegate methods
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            self.currentLocation = location
            logger.debug("Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            print("Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)")
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("Location manager failed with error: \(error.localizedDescription)")
        print("Location manager failed with error: \(error.localizedDescription)")
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            logger.info("Location access authorized")
            print("Location access authorized")
            manager.startUpdatingLocation()
        case .denied, .restricted:
            logger.error("Location access denied or restricted")
            print("Location access denied or restricted")
        case .notDetermined:
            logger.debug("Location access not determined")
            print("Location access not determined")
        @unknown default:
            logger.warning("Unknown authorization status")
            print("Unknown authorization status")
        }
    }
}
