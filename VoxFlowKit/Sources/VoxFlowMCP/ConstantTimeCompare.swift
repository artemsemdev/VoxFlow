import Foundation

/// Compares two strings' UTF-8 bytes in constant time, always iterating the full length of the
/// longer input, so a bearer-token comparison doesn't leak how many leading bytes matched via
/// timing.
public func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8)
    let bBytes = Array(b.utf8)
    let length = max(aBytes.count, bBytes.count)

    var mismatch: UInt8 = aBytes.count == bBytes.count ? 0 : 1
    for index in 0..<length {
        let byteA = index < aBytes.count ? aBytes[index] : 0
        let byteB = index < bBytes.count ? bBytes[index] : 0
        mismatch |= byteA ^ byteB
    }
    return mismatch == 0
}
