import Darwin
import Foundation

/// Validates optional Mac Hub LAN sync endpoints to prevent SSRF, arbitrary scheme
/// abuse (`file://`, `ftp://`), public internet exfiltration, or link-local metadata probing.
public enum LANEndpointValidator {
    public static func validatedEndpoint(baseURLString: String, apiPath: String) -> URL? {
        let trimmed = baseURLString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty,
              trimmed.count <= 256,
              !trimmed.contains("\0"),
              !trimmed.contains("\r"),
              !trimmed.contains("\n"),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty
        else {
            return nil
        }

        if let port = components.port, !(1...65535).contains(port) {
            return nil
        }

        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard isAllowedLANHost(host) else {
            return nil
        }

        let cleanPath = apiPath.hasPrefix("/") ? apiPath : "/\(apiPath)"
        guard !cleanPath.contains("\0"), !cleanPath.contains("\r"), !cleanPath.contains("\n") else {
            return nil
        }
        let hostOut = host.contains(":") ? "[\(host)]" : host
        let portOut = components.port.map { ":\($0)" } ?? ""
        return URL(string: "\(scheme)://\(hostOut)\(portOut)\(cleanPath)")
    }

    public static func isAllowedLANHost(_ rawHost: String) -> Bool {
        let host = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard !host.isEmpty else { return false }

        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return true
        }

        // Bonjour / mDNS single-label `.local` hostnames
        if host.hasSuffix(".local") {
            let label = String(host.dropLast(6))
            guard !label.isEmpty, label.count <= 63, !label.contains(".") else { return false }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
            return !label.hasPrefix("-")
                && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }

        // IPv4 strict RFC1918 private network check (reject leading zeros to prevent octal IP SSRF)
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4 {
            let parsed = octets.compactMap { part -> Int? in
                guard !part.isEmpty,
                      part.count <= 3,
                      !(part.count > 1 && part.hasPrefix("0")),
                      part.allSatisfy(\.isNumber),
                      let n = Int(part),
                      (0...255).contains(n)
                else {
                    return nil
                }
                return n
            }
            guard parsed.count == 4 else { return false }
            let a = parsed[0], b = parsed[1]
            if a == 10 { return true }
            if a == 172 && (16...31).contains(b) { return true }
            if a == 192 && b == 168 { return true }
            if a == 127 { return true }
            return false
        }

        // Strict IPv6 validation via inet_pton: allow only ::1 loopback or Unique Local Address (fc00::/7)
        if host.contains(":") {
            var addr6 = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &addr6) }) == 1 else {
                return false
            }
            let bytes = withUnsafeBytes(of: addr6.__u6_addr.__u6_addr8) { Array($0) }
            guard bytes.count == 16 else { return false }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
            let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
            return isLoopback || isUniqueLocal
        }

        return false
    }
}

/// Validates `pocketcoffee://` deep links, persisted record IDs, and imported media extensions.
public enum DeepLinkValidator {
    public static let allowedMediaExtensions: Set<String> = [
        "mov", "mp4", "m4v", "webm", "mkv", "avi", "3gp",
        "m4a", "wav", "mp3", "aac", "caf", "ogg", "oga", "flac", "opus", "aif", "aiff",
        "jpg", "jpeg", "png", "heic", "heif", "webp",
    ]

    public enum Route: Equatable {
        case importLatest
        case openReport(String)
    }

    public static func sanitizeRecordID(_ raw: String?) -> String? {
        guard let trimmed = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              !trimmed.isEmpty,
              trimmed.count <= 64
        else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    public static func sanitizeMediaExtension(_ raw: String?, fallback: String = "mov") -> String {
        let cleaned = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return allowedMediaExtensions.contains(cleaned) ? cleaned : fallback
    }

    public static func parse(_ url: URL) -> Route? {
        let raw = url.absoluteString
        guard raw.count <= 512,
              !raw.contains("\0"),
              !raw.contains("\r"),
              !raw.contains("\n"),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.scheme?.lowercased() == "pocketcoffee",
              comps.user == nil,
              comps.password == nil
        else {
            return nil
        }
        let host = (comps.host ?? "").lowercased()
        switch host {
        case "import-latest", "import":
            guard comps.percentEncodedPath.isEmpty || comps.percentEncodedPath == "/" else { return nil }
            return .importLatest
        case "report":
            guard let id = sanitizeRecordID(comps.path) else { return nil }
            return .openReport(id)
        default:
            return nil
        }
    }
}

/// Resolves persisted local file paths across iOS app reinstalls / container UUID rotations
/// and migrates legacy `Library/Caches/PocketCoffeeKeyframes` references transparently.
public enum SandboxPathResolver {

    public static func defaultDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    public static func defaultCachesDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    public static func defaultApplicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? defaultDocumentsDirectory()
    }

    private static func containsTraversalOrControl(_ path: String) -> Bool {
        if path.contains("\0") || path.contains("\r") || path.contains("\n") {
            return true
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/", omittingEmptySubsequences: true).contains("..")
    }

    private static func validateSafeRegularMediaFile(_ candidateURL: URL, allowedRoots: [URL]?) -> String? {
        let ext = candidateURL.pathExtension.lowercased()
        guard DeepLinkValidator.allowedMediaExtensions.contains(ext) else {
            return nil
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: candidateURL.path) else {
            return nil
        }

        guard let values = try? candidateURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            return nil
        }

        let canonicalURL = candidateURL.resolvingSymlinksInPath()
        let canonicalParent = candidateURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard canonicalURL.deletingLastPathComponent().path == canonicalParent.path else {
            return nil
        }

        let canonicalPath = canonicalURL.path
        let blockedSystemPrefixes = ["/etc/", "/private/etc/", "/System/", "/dev/", "/proc/"]
        if blockedSystemPrefixes.contains(where: { canonicalPath.hasPrefix($0) })
            || canonicalPath.contains("/.ssh/")
            || canonicalPath.contains("/.aws/")
            || canonicalPath.contains("/.gnupg/") {
            return nil
        }

        if let allowedRoots {
            let insideAllowedRoot = allowedRoots.contains { root in
                let rootPath = root.resolvingSymlinksInPath().path
                let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                return canonicalPath.hasPrefix(prefix)
            }
            guard insideAllowedRoot else { return nil }
        }

        return canonicalPath
    }

    /// Validates a target output directory before creating files (such as 2.5s close-up video clips),
    /// rejecting `..` traversal, control characters, symbolic links, sensitive system directories,
    /// and (on iOS or when explicit sandbox roots are given) directories outside the app sandbox.
    public static func validateWritableDirectory(
        _ directoryURL: URL,
        documentsDirectory: URL? = nil,
        cachesDirectory: URL? = nil,
        applicationSupportDirectory: URL? = nil,
        additionalAllowedRoots: [URL] = []
    ) -> URL? {
        guard directoryURL.isFileURL else { return nil }
        let rawPath = directoryURL.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty, rawPath.hasPrefix("/"), !containsTraversalOrControl(rawPath) else {
            return nil
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: rawPath, isDirectory: &isDir) {
            guard isDir.boolValue else { return nil }
            if let values = try? directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                return nil
            }
        }

        let canonicalURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalPath = canonicalURL.path
        let blockedSystemPrefixes = ["/etc", "/private/etc", "/System", "/dev", "/proc", "/var/root", "/private/var/root"]
        if blockedSystemPrefixes.contains(where: { canonicalPath == $0 || canonicalPath.hasPrefix($0 + "/") })
            || canonicalPath.contains("/.ssh")
            || canonicalPath.contains("/.aws")
            || canonicalPath.contains("/.gnupg") {
            return nil
        }

        let customRootsProvided = documentsDirectory != nil
            || cachesDirectory != nil
            || applicationSupportDirectory != nil
            || !additionalAllowedRoots.isEmpty
        let docsDir = documentsDirectory ?? defaultDocumentsDirectory()
        let cachesDir = cachesDirectory ?? defaultCachesDirectory()
        let appSupportDir = applicationSupportDirectory ?? defaultApplicationSupportDirectory()
        let sandboxRoots: [URL] = (customRootsProvided
            ? [docsDir, cachesDir, appSupportDir]
            : [docsDir, cachesDir, appSupportDir, fm.temporaryDirectory]) + additionalAllowedRoots

        #if os(iOS)
        let enforceRoots = true
        #else
        let enforceRoots = customRootsProvided
        #endif

        if enforceRoots {
            let insideAllowed = sandboxRoots.contains { root in
                let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
                let cleanRoot = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
                return canonicalPath == cleanRoot || canonicalPath.hasPrefix(cleanRoot + "/")
            }
            guard insideAllowed else { return nil }
        }

        return canonicalURL
    }

    /// Resolves a stored file path on disk. If the exact absolute path no longer exists
    /// (for example because iOS rotated the app sandbox container UUID on reinstall),
    /// rebases the relative path under the current `Documents`, `Library/Caches`, or
    /// `Library/Application Support` directory.
    public static func resolveLocalFilePath(
        _ storedPath: String?,
        documentsDirectory: URL? = nil,
        cachesDirectory: URL? = nil,
        applicationSupportDirectory: URL? = nil,
        additionalAllowedRoots: [URL] = []
    ) -> String? {
        guard let raw = storedPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !containsTraversalOrControl(raw)
        else {
            return nil
        }

        let customRootsProvided = documentsDirectory != nil
            || cachesDirectory != nil
            || applicationSupportDirectory != nil
        let docsDir = documentsDirectory ?? defaultDocumentsDirectory()
        let cachesDir = cachesDirectory ?? defaultCachesDirectory()
        let appSupportDir = applicationSupportDirectory ?? defaultApplicationSupportDirectory()
        let sandboxRoots: [URL] = (customRootsProvided
            ? [docsDir, cachesDir, appSupportDir]
            : [docsDir, cachesDir, appSupportDir, FileManager.default.temporaryDirectory]) + additionalAllowedRoots

        #if os(iOS)
        let directRoots: [URL]? = sandboxRoots
        #else
        let directRoots: [URL]? = customRootsProvided ? sandboxRoots : nil
        #endif

        if raw.hasPrefix("/"),
           let directMatch = validateSafeRegularMediaFile(URL(fileURLWithPath: raw), allowedRoots: directRoots) {
            return directMatch
        }

        var candidates: [URL] = []

        if let range = raw.range(of: "/Documents/") {
            let rel = String(raw[range.upperBound...])
            if !rel.isEmpty && !containsTraversalOrControl(rel) {
                candidates.append(docsDir.appendingPathComponent(rel))
            }
        }

        if let range = raw.range(of: "/Library/Caches/") {
            let rel = String(raw[range.upperBound...])
            if !rel.isEmpty && !containsTraversalOrControl(rel) {
                candidates.append(cachesDir.appendingPathComponent(rel))
                if let kfRange = rel.range(of: "PocketCoffeeKeyframes/") {
                    let kfSub = String(rel[kfRange.upperBound...])
                    if !kfSub.isEmpty && !containsTraversalOrControl(kfSub) {
                        candidates.append(
                            docsDir
                                .appendingPathComponent("PocketCoffeeData/Keyframes", isDirectory: true)
                                .appendingPathComponent(kfSub)
                        )
                    }
                }
            }
        }

        if let range = raw.range(of: "/Library/Application Support/") {
            let rel = String(raw[range.upperBound...])
            if !rel.isEmpty && !containsTraversalOrControl(rel) {
                candidates.append(appSupportDir.appendingPathComponent(rel))
            }
        }

        if !raw.hasPrefix("/") {
            candidates.append(docsDir.appendingPathComponent(raw))
            candidates.append(cachesDir.appendingPathComponent(raw))
        }

        for candidate in candidates {
            if let resolved = validateSafeRegularMediaFile(candidate, allowedRoots: sandboxRoots) {
                return resolved
            }
        }

        return nil
    }

    /// Returns a copy of `record` with `videoPath`, `mediaURL`, and every keyframe `imagePath`
    /// rebased to the current sandbox container if needed.
    public static func resolveRecordPaths(
        _ record: CoffeeRecord,
        documentsDirectory: URL? = nil,
        cachesDirectory: URL? = nil,
        applicationSupportDirectory: URL? = nil
    ) -> CoffeeRecord {
        var copy = record

        if let resolvedVideo = resolveLocalFilePath(
            record.videoPath,
            documentsDirectory: documentsDirectory,
            cachesDirectory: cachesDirectory,
            applicationSupportDirectory: applicationSupportDirectory
        ) {
            copy.videoPath = resolvedVideo
        }

        if let resolvedMedia = resolveLocalFilePath(
            record.mediaURL,
            documentsDirectory: documentsDirectory,
            cachesDirectory: cachesDirectory,
            applicationSupportDirectory: applicationSupportDirectory
        ) {
            copy.mediaURL = resolvedMedia
        }

        copy.keyframes = record.keyframes.map { kf in
            var updated = kf
            if let resolvedImage = resolveLocalFilePath(
                kf.imagePath,
                documentsDirectory: documentsDirectory,
                cachesDirectory: cachesDirectory,
                applicationSupportDirectory: applicationSupportDirectory
            ) {
                updated.imagePath = resolvedImage
            }
            return updated
        }

        return copy
    }

    /// Single source of truth for Xiaohongshu carousel keyframe cards:
    /// resolves container-rotated paths and keeps every extracted keyframe whose file exists on disk.
    public static func exportableXiaohongshuKeyframes(
        for record: CoffeeRecord,
        documentsDirectory: URL? = nil,
        cachesDirectory: URL? = nil,
        applicationSupportDirectory: URL? = nil
    ) -> [KeyframeObservation] {
        let resolved = resolveRecordPaths(
            record,
            documentsDirectory: documentsDirectory,
            cachesDirectory: cachesDirectory,
            applicationSupportDirectory: applicationSupportDirectory
        )
        return resolved.keyframes.filter { kf in
            guard kf.extracted, let path = kf.imagePath, !path.isEmpty else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }
}
