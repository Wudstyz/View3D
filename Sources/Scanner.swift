import Foundation

/// Lecture rapide d'un tampon d'octets terminé par un 0 (texte ASCII : OBJ, PLY, STL).
struct LineScanner {
    var p: UnsafePointer<UInt8>
    let end: UnsafePointer<UInt8>

    @inline(__always) var atEnd: Bool { p >= end }

    @inline(__always) mutating func skipSpaces() {
        while p < end, p.pointee == 32 || p.pointee == 9 || p.pointee == 13 { p += 1 }
    }

    /// Lit un mot (jusqu'au prochain espace).
    mutating func word() -> UnsafeBufferPointer<UInt8>? {
        skipSpaces()
        if p >= end { return nil }
        let s = p
        while p < end, p.pointee != 32, p.pointee != 9, p.pointee != 13 { p += 1 }
        return UnsafeBufferPointer(start: s, count: p - s)
    }

    mutating func float() -> Float? {
        skipSpaces()
        if p >= end { return nil }
        var e: UnsafeMutablePointer<CChar>?
        let v = p.withMemoryRebound(to: CChar.self, capacity: 1) { cp -> Float in
            let r = strtof(cp, &e)
            if let e = e { p = UnsafePointer<UInt8>(OpaquePointer(e)) }
            return r
        }
        return v
    }

    mutating func double() -> Double? {
        skipSpaces()
        if p >= end { return nil }
        var e: UnsafeMutablePointer<CChar>?
        let v = p.withMemoryRebound(to: CChar.self, capacity: 1) { cp -> Double in
            let r = strtod(cp, &e)
            if let e = e { p = UnsafePointer<UInt8>(OpaquePointer(e)) }
            return r
        }
        return v
    }

    mutating func int() -> Int? {
        skipSpaces()
        if p >= end { return nil }
        var neg = false
        if p.pointee == 45 { neg = true; p += 1 } else if p.pointee == 43 { p += 1 }
        var any = false
        var v = 0
        while p < end, p.pointee >= 48, p.pointee <= 57 { v = v &* 10 &+ Int(p.pointee &- 48); p += 1; any = true }
        return any ? (neg ? -v : v) : nil
    }

    /// Lit le reste de la ligne comme texte.
    mutating func rest() -> String {
        skipSpaces()
        var e = end
        while e > p, e[-1] == 32 || e[-1] == 13 || e[-1] == 9 { e -= 1 }
        return String(decoding: UnsafeBufferPointer(start: p, count: e - p), as: UTF8.self)
    }
}

@inline(__always) func wordEquals(_ w: UnsafeBufferPointer<UInt8>, _ s: StaticString) -> Bool {
    if w.count != s.utf8CodeUnitCount { return false }
    let sp = s.utf8Start
    for i in 0..<w.count where w[i] != sp[i] { return false }
    return true
}

/// Parcourt un tampon texte ligne par ligne.
func forEachLine(_ bytes: [UInt8], from start: Int = 0, _ body: (inout LineScanner) -> Void) {
    bytes.withUnsafeBufferPointer { buf in
        guard let base = buf.baseAddress else { return }
        let total = buf.count - 1          // dernier octet = 0 ajouté
        var i = start
        while i < total {
            let s = base + i
            var e = s
            let limit = base + total
            while e < limit, e.pointee != 10 { e += 1 }
            var sc = LineScanner(p: s, end: e)
            body(&sc)
            i = (e - base) + 1
        }
    }
}

func readTextBuffer(_ url: URL) throws -> [UInt8] {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    var bytes = [UInt8](data)
    bytes.append(0)
    return bytes
}
