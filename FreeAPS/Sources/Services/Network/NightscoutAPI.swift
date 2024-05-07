import Combine
import CommonCrypto
import Foundation
import JavaScriptCore
import Swinject

class NightscoutAPI {
    init(url: URL, secret: String? = nil) {
        self.url = url
        self.secret = secret?.nonEmpty
    }

    private enum Config {
        static let entriesPath = "/api/v1/entries/sgv.json"
        static let uploadEntriesPath = "/api/v1/entries.json"
        static let treatmentsPath = "/api/v1/treatments.json"
        static let statusPath = "/api/v1/devicestatus.json"
        static let profilePath = "/api/v1/profile.json"
        static let retryCount = 1
        static let timeout: TimeInterval = 60
    }

    enum Error: LocalizedError {
        case badStatusCode
        case missingURL
    }

    let url: URL
    let secret: String?

    private let service = NetworkService()

    @Injected() private var settingsManager: SettingsManager!
}

extension NightscoutAPI {
    func checkConnection() -> AnyPublisher<Void, Swift.Error> {
        struct Check: Codable, Equatable {
            var eventType = "Note"
            var enteredBy = "Open-iAPS"
            var notes = "Open-iAPS connected"
        }
        let check = Check()
        var request = URLRequest(url: url.appendingPathComponent(Config.treatmentsPath))

        if let secret = secret {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpMethod = "POST"
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
            request.httpBody = try! JSONCoding.encoder.encode(check)
        } else {
            request.httpMethod = "GET"
        }

        return service.run(request)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func fetchLastGlucose(sinceDate: Date? = nil) -> AnyPublisher<[BloodGlucose], Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.entriesPath
        components.queryItems = [URLQueryItem(name: "count", value: "\(1600)")]
        if let date = sinceDate {
            let dateItem = URLQueryItem(
                name: "find[dateString][$gte]",
                value: Formatter.iso8601withFractionalSeconds.string(from: date)
            )
            components.queryItems?.append(dateItem)
        }

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }

        return service.run(request)
            .retry(Config.retryCount)
            .decode(type: [BloodGlucose].self, decoder: JSONCoding.decoder)
            .catch { error -> AnyPublisher<[BloodGlucose], Swift.Error> in
                warning(.nightscout, "Glucose fetching error: \(error.localizedDescription)")
                return Just([]).setFailureType(to: Swift.Error.self).eraseToAnyPublisher()
            }
            .map { glucose in
                glucose
                    .map {
                        var reading = $0
                        reading.glucose = $0.sgv
                        return reading
                    }
            }
            .eraseToAnyPublisher()
    }

    func fetchCarbs(sinceDate: Date? = nil) -> AnyPublisher<[CarbsEntry], Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.treatmentsPath
        components.queryItems = [
            URLQueryItem(name: "find[carbs][$exists]", value: "true"),
            URLQueryItem(
                name: "find[enteredBy][$ne]",
                value: CarbsEntry.manual.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
            ),
            URLQueryItem(
                name: "find[enteredBy][$ne]",
                value: NightscoutTreatment.local.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
            )
        ]
        if let date = sinceDate {
            let dateItem = URLQueryItem(
                name: "find[created_at][$gt]",
                value: Formatter.iso8601withFractionalSeconds.string(from: date)
            )
            components.queryItems?.append(dateItem)
        }

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }

        return service.run(request)
            .retry(Config.retryCount)
            .decode(type: [CarbsEntry].self, decoder: JSONCoding.decoder)
            .catch { error -> AnyPublisher<[CarbsEntry], Swift.Error> in
                warning(.nightscout, "Carbs fetching error: \(error.localizedDescription)")
                return Just([]).setFailureType(to: Swift.Error.self).eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    func deleteCarbs(at date: Date) -> AnyPublisher<Void, Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.treatmentsPath
        components.queryItems = [
            URLQueryItem(name: "find[carbs][$exists]", value: "true"),
            URLQueryItem(
                name: "find[created_at][$eq]",
                value: Formatter.iso8601withFractionalSeconds.string(from: date)
            )
        ]

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout
        request.httpMethod = "DELETE"

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }

        return service.run(request)
            .retry(Config.retryCount)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func deleteInsulin(at date: Date) -> AnyPublisher<Void, Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.treatmentsPath
        components.queryItems = [
            URLQueryItem(name: "find[bolus][$exists]", value: "true"),
            URLQueryItem(
                name: "find[created_at][$eq]",
                value: Formatter.iso8601withFractionalSeconds.string(from: date)
            )
        ]

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout
        request.httpMethod = "DELETE"

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }

        return service.run(request)
            .retry(Config.retryCount)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func fetchTempTargets(sinceDate: Date? = nil) -> AnyPublisher<[TempTarget], Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.treatmentsPath
        components.queryItems = [
            URLQueryItem(name: "find[eventType]", value: "Temporary+Target"),
            URLQueryItem(
                name: "find[enteredBy][$ne]",
                value: TempTarget.manual.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
            ),
            URLQueryItem(
                name: "find[enteredBy][$ne]",
                value: NightscoutTreatment.local.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
            ),
            URLQueryItem(name: "find[duration][$exists]", value: "true")
        ]
        if let date = sinceDate {
            let dateItem = URLQueryItem(
                name: "find[created_at][$gt]",
                value: Formatter.iso8601withFractionalSeconds.string(from: date)
            )
            components.queryItems?.append(dateItem)
        }

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }

        return service.run(request)
            .retry(Config.retryCount)
            .decode(type: [TempTarget].self, decoder: JSONCoding.decoder)
            .catch { error -> AnyPublisher<[TempTarget], Swift.Error> in
                warning(.nightscout, "TempTarget fetching error: \(error.localizedDescription)")
                return Just([]).setFailureType(to: Swift.Error.self).eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    /// fetch the overrides available in NS as a exercice since the date specified in the parameter
    /// Limit to exercice with the attribute enteredBy = the name of local app (as defined in NightscoutExercice
    /// - Parameter sinceDate: the oldest date to fetch exercices
    /// - Returns: A publisher with a array of NightscoutExercice or error
    func fetchOverrides(sinceDate: Date? = nil) -> AnyPublisher<[NightscoutExercice], Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.treatmentsPath
        components.queryItems = [
            URLQueryItem(name: "find[eventType]", value: "Exercice"),
            URLQueryItem(
                name: "find[enteredBy]",
                value: NightscoutExercice.local.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
            )
        ]
        if let date = sinceDate {
            let dateItem = URLQueryItem(
                name: "find[created_at][$gt]",
                value: Formatter.iso8601withFractionalSeconds.string(from: date)
            )
            components.queryItems?.append(dateItem)
        }

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }

        return service.run(request)
            .retry(Config.retryCount)
            .decode(type: [NightscoutExercice].self, decoder: JSONCoding.decoder)
            .catch { error -> AnyPublisher<[NightscoutExercice], Swift.Error> in
                warning(.nightscout, "Override fetching error: \(error.localizedDescription)")
                return Just([]).setFailureType(to: Swift.Error.self).eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    func fetchAnnouncement(sinceDate: Date? = nil) -> AnyPublisher<[Announcement], Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.treatmentsPath
        components.queryItems = [
            URLQueryItem(name: "find[eventType]", value: "Announcement"),
            URLQueryItem(
                name: "find[enteredBy]",
                value: Announcement.remote.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
            )
        ]
        if let date = sinceDate {
            let dateItem = URLQueryItem(
                name: "find[created_at][$gte]",
                value: Formatter.iso8601withFractionalSeconds.string(from: date)
            )
            components.queryItems?.append(dateItem)
        }

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }

        return service.run(request)
            .retry(Config.retryCount)
            .decode(type: [Announcement].self, decoder: JSONCoding.decoder)
            .eraseToAnyPublisher()
    }

    func uploadTreatments(_ treatments: [NightscoutTreatment]) -> AnyPublisher<Void, Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.treatmentsPath

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }
        request.httpBody = try! JSONCoding.encoder.encode(treatments)
        request.httpMethod = "POST"

        return service.run(request)
            .retry(Config.retryCount)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func uploadGlucose(_ glucose: [BloodGlucose]) -> AnyPublisher<Void, Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.uploadEntriesPath

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }
        request.httpBody = try! JSONCoding.encoder.encode(glucose)
        request.httpMethod = "POST"

        return service.run(request)
            .retry(Config.retryCount)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func uploadStats(_ stats: NightscoutStatistics) -> AnyPublisher<Void, Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.statusPath

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }
        request.httpBody = try! JSONCoding.encoder.encode(stats)
        request.httpMethod = "POST"

        return service.run(request)
            .retry(Config.retryCount)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func uploadStatus(_ status: NightscoutStatus) -> AnyPublisher<Void, Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.statusPath

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }
        request.httpBody = try! JSONCoding.encoder.encode(status)
        request.httpMethod = "POST"

        return service.run(request)
            .retry(Config.retryCount)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func uploadPrefs(_ prefs: NightscoutPreferences) -> AnyPublisher<Void, Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.statusPath

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }
        request.httpBody = try! JSONCoding.encoder.encode(prefs)
        request.httpMethod = "POST"

        return service.run(request)
            .retry(Config.retryCount)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func uploadSettings(_ settings: NightscoutSettings) -> AnyPublisher<Void, Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.statusPath

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }
        request.httpBody = try! JSONCoding.encoder.encode(settings)
        request.httpMethod = "POST"

        return service.run(request)
            .retry(Config.retryCount)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func uploadProfile(_ profile: NightscoutProfileStore) -> AnyPublisher<Void, Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.profilePath

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }
        request.httpBody = try! JSONCoding.encoder.encode(profile)
        request.httpMethod = "POST"

        return service.run(request)
            .retry(Config.retryCount)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// Upload old, new and updated overrides in NS as a exercice.
    /// - Parameter overrides: a array of NightscoutExercice to upload
    /// - Returns: A publisher with only error response.
    func uploadOverrides(_ overrides: [NightscoutExercice]) -> AnyPublisher<Void, Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.treatmentsPath

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }
        request.httpBody = try! JSONCoding.encoder.encode(overrides)
        request.httpMethod = "POST"

        return service.run(request)
            .retry(Config.retryCount)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// delete a override in NS as exercice for a specific date
    /// - Parameter date: the date of the override to delete
    /// - Returns: A publisher with only error response.
    func deleteOverride(at date: Date) -> AnyPublisher<Void, Swift.Error> {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = Config.treatmentsPath
        components.queryItems = [
            URLQueryItem(name: "find[eventType]", value: "Exercice"),
            URLQueryItem(
                name: "find[created_at][$eq]",
                value: Formatter.iso8601withFractionalSeconds.string(from: date)
            )
        ]

        var request = URLRequest(url: components.url!)
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = Config.timeout
        request.httpMethod = "DELETE"

        if let secret = secret {
            request.addValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }

        return service.run(request)
            .retry(Config.retryCount)
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}

private extension String {
    func sha1() -> String {
        let data = Data(utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }
        let hexBytes = digest.map { String(format: "%02hhx", $0) }
        return hexBytes.joined()
    }
}
