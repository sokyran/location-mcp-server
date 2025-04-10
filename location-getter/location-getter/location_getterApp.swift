import Foundation
import CoreLocation
import Network

// MARK: - Location Manager
class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    
    private let locationManager = CLLocationManager()
    private var currentLocation: CLLocation?
    private var locationUpdateHandler: ((CLLocation) -> Void)?
    
    private override init() {
        super.init()
        
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.startUpdatingLocation()
    }
    
    func requestLocationPermission() {
        locationManager.requestAlwaysAuthorization()
    }
    
    func getCurrentLocation(completion: @escaping (CLLocation?) -> Void) {
        if let location = currentLocation {
            completion(location)
        } else {
            locationUpdateHandler = { location in
                completion(location)
                self.locationUpdateHandler = nil
            }
        }
    }
    
    // MARK: - CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        currentLocation = location
        locationUpdateHandler?(location)
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}

// MARK: - HTTP Server
class HTTPServer {
    private var listener: NWListener?
    private let port: UInt16
    
    init(port: UInt16 = 8080) {
        self.port = port
    }
    
    func start() {
        do {
            let parameters = NWParameters.tcp
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("Server listening on port \(self.port)")
                case .failed(let error):
                    print("Server failure: \(error.localizedDescription)")
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { connection in
                self.handleConnection(connection)
            }
            
            listener?.start(queue: .main)
        } catch {
            print("Failed to start server: \(error.localizedDescription)")
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receiveRequest(on: connection)
            case .failed(let error):
                print("Connection failed: \(error.localizedDescription)")
                connection.cancel()
            default:
                break
            }
        }
        
        connection.start(queue: .main)
    }
    
    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                let request = String(data: data, encoding: .utf8) ?? ""
                
                if request.contains("GET /location") {
                    self.sendLocationResponse(on: connection)
                } else {
                    self.sendResponse(on: connection, statusCode: 404, body: "Not Found")
                }
            } else if let error = error {
                print("Receive error: \(error.localizedDescription)")
                connection.cancel()
            } else if isComplete {
                connection.cancel()
            }
        }
    }
    
    private func sendLocationResponse(on connection: NWConnection) {
        LocationService.shared.getCurrentLocation { location in
            var responseBody = "Location not available"
            
            if let location = location {
                let latitude = location.coordinate.latitude
                let longitude = location.coordinate.longitude
                let accuracy = location.horizontalAccuracy
                let timestamp = ISO8601DateFormatter().string(from: location.timestamp)
                
                responseBody = """
                {
                    "latitude": \(latitude),
                    "longitude": \(longitude),
                    "accuracy": \(accuracy),
                    "timestamp": "\(timestamp)"
                }
                """
            }
            
            self.sendResponse(on: connection, statusCode: 200, body: responseBody, contentType: "application/json")
        }
    }
    
    private func sendResponse(on connection: NWConnection, statusCode: Int, body: String, contentType: String = "text/plain") {
        let response = """
        HTTP/1.1 \(statusCode) \(statusCode == 200 ? "OK" : "Not Found")
        Content-Type: \(contentType)
        Content-Length: \(body.utf8.count)
        Connection: close

        \(body)
        """
        
        let data = response.data(using: .utf8)!
        
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("Send error: \(error.localizedDescription)")
            }
            connection.cancel()
        })
    }
}

// MARK: - App
class BackgroundLocationApp {
    private let server: HTTPServer
    
    init() {
        server = HTTPServer(port: 8080)
        
        // Request location permissions
        LocationService.shared.requestLocationPermission()
        
        // Start the server
        server.start()
        
        print("Background Location Service started on port 8080")
        print("To get location, use: curl http://localhost:8080/location")
    }
}

// Initialize the app
let app = BackgroundLocationApp()

// Keep the app running
RunLoop.main.run()
