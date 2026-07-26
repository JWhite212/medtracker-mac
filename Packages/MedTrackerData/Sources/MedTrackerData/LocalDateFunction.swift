import Foundation
import GRDB
import MedTrackerCore

/// A thread-safe cache of `TimeZone` lookups keyed by IANA identifier.
/// `TimeZone(identifier:)` parses tzdata on first use per identifier; since
/// `localDate` is called once per row in a `GROUP BY`, caching avoids
/// repeating that lookup across a whole result set.
private final class TimeZoneCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: TimeZone] = [:]

    func timeZone(for identifier: String) -> TimeZone {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[identifier] {
            return cached
        }
        let resolved = TimeZone(identifier: identifier) ?? TimeZone(identifier: "UTC")!
        cache[identifier] = resolved
        return resolved
    }
}

private let timeZoneCache = TimeZoneCache()

/// Registered GRDB SQL function: `localDate(epochSeconds, tzIdentifier) ->
/// TEXT` — the `yyyy-MM-dd` local calendar date of a UTC epoch-seconds
/// value in the given IANA timezone.
///
/// This is what lets `GROUP BY localDate(taken_at, ?)` style queries bucket
/// rows by the **user's profile timezone** entirely in SQL, rather than
/// pulling every row into Swift to bucket — exactly the aggregation the web
/// app does with Postgres `date_trunc`/`AT TIME ZONE`, and honoring the
/// Global Constraint that day-boundary math must use the profile tz, never
/// the ambient device tz.
///
/// Delegates the actual date-component math to
/// `MedTrackerCore.localDateString`, so this function and every pure
/// Swift-side date computation share one DST-correct implementation.
public let localDateFunction = DatabaseFunction(
    "localDate",
    argumentCount: 2,
    pure: true
) { values -> DatabaseValueConvertible? in
    guard let epochSeconds = Double.fromDatabaseValue(values[0]),
          let tzIdentifier = String.fromDatabaseValue(values[1])
    else {
        return nil
    }

    let date = Date(timeIntervalSince1970: epochSeconds)
    let timeZone = timeZoneCache.timeZone(for: tzIdentifier)
    return localDateString(date, timeZone: timeZone)
}
