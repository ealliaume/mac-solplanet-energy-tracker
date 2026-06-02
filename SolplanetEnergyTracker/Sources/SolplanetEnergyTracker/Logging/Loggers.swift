import Foundation

/// Shared, process-wide loggers. The update machinery (an actor graph that runs
/// off the main actor) needs a logger it can reach without threading one down
/// from `AppDelegate`, so it defaults to `Loggers.app` — the same `app.log`
/// file the rest of the app writes to.
public enum Loggers {
    /// Writes to `~/.cache/solplanet-energy-tracker/app.log`, honouring the
    /// `SOLPLANET_TRACKER_LOG_LEVEL` env override like the AppDelegate logger.
    public static let app = FileLogger(
        fileURL: CacheDirectory.makeDefault().appLogURL,
        minLevel: LogLevel.parse(ProcessInfo.processInfo.environment[AppInfo.logLevelEnvKey]) ?? .info
    )
}
