import Foundation

/// A cuid2-shaped identifier generator.
///
/// This does NOT aim for byte-for-byte compatibility with the JS
/// `@paralleldrive/cuid2` package — only for the same externally-visible
/// shape: a 24-character, lowercase, base36 string starting with a letter.
/// That's sufficient because these ids only need to be valid `TEXT` primary
/// keys locally; ids that originate from the web app arrive via sync and are
/// stored verbatim rather than being generated here.
///
/// Collision resistance comes from combining a monotonically increasing
/// per-process counter with random entropy and a high-resolution timestamp,
/// then hashing the combination with `Hasher` (SipHash) multiple times with
/// distinct seeds to produce enough bits for the 23-character base36 body.
/// No external dependency (e.g. swift-crypto) is required.
enum Cuid2 {
    private static let base36Alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    /// Process-wide monotonically increasing counter, guarded by a lock so
    /// `createId()` is safe to call concurrently.
    private static let counter = Counter()

    private final class Counter: @unchecked Sendable {
        private var value: UInt64 = 0
        private let lock = NSLock()

        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value &+= 1
            return value
        }
    }

    /// Encodes a `UInt64` as base36 digits, left-padded with `0` to `width`
    /// characters (truncating from the left if the encoding is longer).
    private static func base36(_ value: UInt64, width: Int) -> String {
        var v = value
        var digits: [Character] = []
        if v == 0 {
            digits = ["0"]
        } else {
            while v > 0 {
                digits.append(base36Alphabet[Int(v % 36)])
                v /= 36
            }
        }
        var result = String(digits.reversed())
        if result.count < width {
            result = String(repeating: "0", count: width - result.count) + result
        } else if result.count > width {
            result = String(result.suffix(width))
        }
        return result
    }

    /// Generates a collision-resistant, cuid2-shaped 24-character id:
    /// one random lowercase letter followed by 23 base36 characters.
    static func createId() -> String {
        let n = counter.next()
        let random1 = UInt64.random(in: .min ... .max)
        let random2 = UInt64.random(in: .min ... .max)
        let timestamp = DispatchTime.now().uptimeNanoseconds
        let seed = "\(n)-\(random1)-\(random2)-\(timestamp)"

        // Combine several independently-seeded hashes of the same input to
        // get enough entropy bits for a 23-character base36 body (~119 bits).
        var hasher1 = Hasher()
        hasher1.combine(seed)
        hasher1.combine(0)
        let h1 = UInt64(bitPattern: Int64(hasher1.finalize()))

        var hasher2 = Hasher()
        hasher2.combine(seed)
        hasher2.combine(1)
        let h2 = UInt64(bitPattern: Int64(hasher2.finalize()))

        var hasher3 = Hasher()
        hasher3.combine(seed)
        hasher3.combine(2)
        let h3 = UInt64(bitPattern: Int64(hasher3.finalize()))

        // 8 base36 chars per 64-bit chunk covers the 23-character body.
        let body = base36(h1, width: 8) + base36(h2, width: 8) + base36(h3, width: 8)
        let bodyChars = String(body.prefix(23))

        let letter = Character(UnicodeScalar(UInt8(97 + Int.random(in: 0..<26))))

        return String(letter) + bodyChars
    }
}

/// Generates a collision-resistant, cuid2-shaped 24-character id.
///
/// Shape: a lowercase letter (`a`-`z`) followed by 23 lowercase
/// base36 (`0-9a-z`) characters. Not byte-for-byte compatible with the JS
/// `@paralleldrive/cuid2` package — see `Cuid2` for rationale.
public func createId() -> String {
    Cuid2.createId()
}
