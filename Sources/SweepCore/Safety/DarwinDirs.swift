import Foundation

public struct DarwinDirs {
    /// Retrieves Darwin per-user cache directory using POSIX confstr(_CS_DARWIN_USER_CACHE_DIR)
    public static var userCacheDir: URL? {
        getPath(for: _CS_DARWIN_USER_CACHE_DIR)
    }

    /// Retrieves Darwin per-user temp directory using POSIX confstr(_CS_DARWIN_USER_TEMP_DIR)
    public static var userTempDir: URL? {
        getPath(for: _CS_DARWIN_USER_TEMP_DIR)
    }

    private static func getPath(for name: Int32) -> URL? {
        let len = confstr(name, nil, 0)
        guard len > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: len)
        confstr(name, &buffer, len)
        let path = String(cString: buffer)
        guard !path.isEmpty else { return nil }

        return URL(fileURLWithPath: path).standardized
    }
}
