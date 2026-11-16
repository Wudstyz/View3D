import Foundation
import SceneKit
import ModelIO
import SceneKit.ModelIO
import Compression
import simd

final class LoadedModel: @unchecked Sendable {
    let node: SCNNode
    let triangles: Int
    let size: [Double]
    init(node: SCNNode, triangles: Int) {
        self.node = node
        self.triangles = triangles
        let (mn, mx) = node.boundingBox
        self.size = [Double(mx.x - mn.x), Double(mx.y - mn.y), Double(mx.z - mn.z)]
    }
}

enum LoadError: LocalizedError {
    case invalid(String), empty, tooBig
    var errorDescription: String? {
        switch self {
        case .invalid(let s): return "Fichier illisible (\(s))"
        case .empty: return "Aucune forme 3D trouvée dans ce fichier"
        case .tooBig: return "Fichier trop volumineux (plus de 1,5 Go)"
        }
    }
}

enum ModelLoader {
    static func load(url: URL, format: ModelFormat) throws -> LoadedModel {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 1_500_000_000 { throw LoadError.tooBig }
        let meshes: [RawMesh]
        switch format {
        case .stl: meshes = try parseSTL(url)
        case .obj: meshes = try parseOBJ(url)
        case .ply: meshes = try parsePLY(url)
        case .threeMF: meshes = try parse3MF(url)
        default: return try loadWithSceneKit(url, format: format)
        }
        let root = SCNNode()
        var tris = 0
        for m in meshes {
            if let (geo, n) = buildGeometry(m) {
                root.addChildNode(SCNNode(geometry: geo))
                tris += n
            }
        }
        if root.childNodes.isEmpty { throw LoadError.empty }
        return LoadedModel(node: root, triangles: tris)
    }

    static func loadWithSceneKit(_ url: URL, format: ModelFormat) throws -> LoadedModel {
        var scene: SCNScene?
        do {
            scene = try SCNScene(url: url, options: [.convertToYUp: true, .checkConsistency: false])
        } catch {
            let asset = MDLAsset(url: url)
            if asset.count > 0 { scene = SCNScene(mdlAsset: asset) }
        }
        guard let scene = scene else { throw LoadError.invalid("format non reconnu") }
        let root = SCNNode()
        for child in scene.rootNode.childNodes { root.addChildNode(child) }
        var tris = 0
        var hasGeometry = false
        root.enumerateHierarchy { node, _ in
            node.camera = nil
            node.light = nil
            if let g = node.geometry {
                hasGeometry = true
                for e in g.elements {
                    switch e.primitiveType {
                    case .triangles, .polygon: tris += e.primitiveCount
                    case .triangleStrip: tris += max(0, e.primitiveCount)
                    default: break
                    }
                }
            }
        }
        if !hasGeometry { throw LoadError.empty }
        return LoadedModel(node: root, triangles: tris)
    }
}

// MARK: - STL

func parseSTL(_ url: URL) throws -> [RawMesh] {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count >= 20 else { throw LoadError.invalid("trop court") }
    var binaryCount = -1
    if data.count >= 84 {
        let c = Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }))
        if 84 + 50 * c == data.count { binaryCount = c }
    }
    var verts: [SIMD3<Float>] = []
    if binaryCount < 0 {
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        if head.hasPrefix("solid") && head.contains("facet") {
            let bytes = try readTextBuffer(url)
            forEachLine(bytes) { sc in
                guard let w = sc.word(), wordEquals(w, "vertex") else { return }
                if let x = sc.float(), let y = sc.float(), let z = sc.float() { verts.append(SIMD3(x, y, z)) }
            }
        } else if data.count >= 84 {
            binaryCount = (data.count - 84) / 50        // binaire un peu tronqué : on lit ce qu'on peut
        } else { throw LoadError.invalid("STL non reconnu") }
    }
    if binaryCount >= 0 {
        verts.reserveCapacity(binaryCount * 3)
        data.withUnsafeBytes { raw in
            for t in 0..<binaryCount {
                let base = 84 + t * 50 + 12
                for k in 0..<3 {
                    let o = base + k * 12
                    verts.append(SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                       raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                       raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)))
                }
            }
        }
    }
    let valid = verts.count - verts.count % 3
    if valid == 0 { throw LoadError.empty }
    if valid != verts.count { verts.removeLast(verts.count - valid) }
    let (p, c) = weld(verts)
    var m = RawMesh(); m.positions = p; m.cornerPos = c
    return [m]
}

// MARK: - OBJ

private final class OBJPart {
    let material: String
    var cornerPos: [UInt32] = []
    var cornerUV: [UInt32] = []
    var cornerN: [Int32] = []
    init(_ m: String) { material = m }
}

private struct MTL { var color: SIMD4<Float>?; var texture: URL? }

func parseOBJ(_ url: URL) throws -> [RawMesh] {
    let bytes = try readTextBuffer(url)
    var positions: [SIMD3<Float>] = []
    var colors: [SIMD4<Float>] = []
    var hasColors = false
    var uvs: [SIMD2<Float>] = []
    var normals: [SIMD3<Float>] = []
    var parts: [OBJPart] = []
    var partIndex: [String: Int] = [:]
    var current = -1
    var curMat = ""
    var mtllibs: [String] = []
    var face: [(Int32, Int32, Int32)] = []

    func selectPart(_ mat: String) {
        if let i = partIndex[mat] { current = i } else {
            parts.append(OBJPart(mat)); partIndex[mat] = parts.count - 1; current = parts.count - 1
        }
    }

    forEachLine(bytes) { sc in
        guard let w = sc.word() else { return }
        if w.count == 1 && w[0] == 118 {                       // v
            guard let x = sc.float(), let y = sc.float(), let z = sc.float() else { return }
            if let r = sc.float(), let g = sc.float(), let b = sc.float() {
                if !hasColors { colors = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: positions.count); hasColors = true }
                colors.append(SIMD4(r, g, b, 1))
            } else if hasColors { colors.append(SIMD4(1, 1, 1, 1)) }
            positions.append(SIMD3(x, y, z))
        } else if wordEquals(w, "vt") {
            if let u = sc.float() { uvs.append(SIMD2(u, sc.float() ?? 0)) }
        } else if wordEquals(w, "vn") {
            if let x = sc.float(), let y = sc.float(), let z = sc.float() { normals.append(SIMD3(x, y, z)) }
        } else if w.count == 1 && w[0] == 102 {                // f
            face.removeAll(keepingCapacity: true)
            while let tok = sc.word() {
                var t = LineScanner(p: tok.baseAddress!, end: tok.baseAddress! + tok.count)
                guard let vi = t.int() else { continue }
                var ti = 0, ni = 0
                if !t.atEnd, t.p.pointee == 47 {
                    t.p += 1
                    if !t.atEnd, t.p.pointee != 47 { ti = t.int() ?? 0 }
                    if !t.atEnd, t.p.pointee == 47 { t.p += 1; ni = t.int() ?? 0 }
                }
                let v = vi < 0 ? positions.count + vi : vi - 1
                if v < 0 || v >= positions.count { face.removeAll(); break }
                let tt = ti == 0 ? -1 : (ti < 0 ? uvs.count + ti : ti - 1)
                let nn = ni == 0 ? -1 : (ni < 0 ? normals.count + ni : ni - 1)
                face.append((Int32(v), Int32(tt >= 0 && tt < uvs.count ? tt : -1), Int32(nn >= 0 && nn < normals.count ? nn : -1)))
            }
            if face.count >= 3 {
                if current < 0 { selectPart(curMat) }
                let part = parts[current]
                for i in 1..<(face.count - 1) {
                    for c in [face[0], face[i], face[i + 1]] {
                        part.cornerPos.append(UInt32(c.0))
                        part.cornerUV.append(c.1 < 0 ? UInt32.max : UInt32(c.1))
                        part.cornerN.append(c.2)
                    }
                }
            }
        } else if wordEquals(w, "usemtl") {
            curMat = sc.rest(); current = -1
            selectPart(curMat)
        } else if wordEquals(w, "mtllib") {
            mtllibs.append(sc.rest())
        }
    }

    if parts.isEmpty || positions.isEmpty {
        // nuage de points ? (OBJ sans faces)
        if !positions.isEmpty {
            var m = RawMesh(); m.positions = positions; m.colors = hasColors ? colors : nil; m.isPointCloud = true
            return [m]
        }
        throw LoadError.empty
    }

    // Matériaux
    var mats: [String: MTL] = [:]
    let dir = url.deletingLastPathComponent()
    for lib in mtllibs {
        let mtlURL = dir.appendingPathComponent(lib.replacingOccurrences(of: "\\", with: "/"))
        guard let mb = try? readTextBuffer(mtlURL) else { continue }
        var name: String?
        var cur = MTL()
        func flush() { if let n = name { mats[n] = cur } }
        forEachLine(mb) { sc in
            guard let w = sc.word() else { return }
            if wordEquals(w, "newmtl") { flush(); name = sc.rest(); cur = MTL() }
            else if wordEquals(w, "Kd") {
                if let r = sc.float(), let g = sc.float(), let b = sc.float() { cur.color = SIMD4(r, g, b, 1) }
            } else if wordEquals(w, "map_Kd") {
                let r = sc.rest().replacingOccurrences(of: "\\", with: "/")
                for cand in [r, r.split(separator: " ").last.map(String.init) ?? r] {
                    for base in [mtlURL.deletingLastPathComponent(), dir] {
                        let u = base.appendingPathComponent(cand)
                        if FileManager.default.fileExists(atPath: u.path) { cur.texture = u; break }
                    }
                    if cur.texture != nil { break }
                }
            }
        }
        flush()
    }

    // Construction des maillages (un par matériau)
    var result: [RawMesh] = []
    var remap = parts.count > 1 ? [Int32](repeating: -1, count: positions.count) : []
    for part in parts where !part.cornerPos.isEmpty {
        var m = RawMesh()
        if parts.count == 1 {
            m.positions = positions
            m.colors = hasColors ? colors : nil
            m.cornerPos = part.cornerPos
        } else {
            var used: [Int] = []
            var cp = [UInt32](); cp.reserveCapacity(part.cornerPos.count)
            for c in part.cornerPos {
                let ci = Int(c)
                var r = remap[ci]
                if r < 0 {
                    r = Int32(m.positions.count); remap[ci] = r
                    m.positions.append(positions[ci]); used.append(ci)
                    if hasColors { if m.colors == nil { m.colors = [] }; m.colors!.append(colors[ci]) }
                }
                cp.append(UInt32(r))
            }
            for u in used { remap[u] = -1 }
            m.cornerPos = cp
        }
        if !uvs.isEmpty, part.cornerUV.contains(where: { $0 != UInt32.max }) { m.uvs = uvs; m.cornerUV = part.cornerUV }
        if !normals.isEmpty, !part.cornerN.contains(where: { $0 < 0 }) {
            m.cornerNormals = part.cornerN.map { normals[Int($0)] }
        }
        if let mt = mats[part.material] { m.color = mt.color; m.texture = mt.texture }
        result.append(m)
    }
    if result.isEmpty { throw LoadError.empty }
    return result
}

// MARK: - PLY

private enum PLYType {
    case i8, u8, i16, u16, i32, u32, f32, f64
    init?(_ s: String) {
        switch s {
        case "char", "int8": self = .i8
        case "uchar", "uint8": self = .u8
        case "short", "int16": self = .i16
        case "ushort", "uint16": self = .u16
        case "int", "int32": self = .i32
        case "uint", "uint32": self = .u32
        case "float", "float32": self = .f32
        case "double", "float64": self = .f64
        default: return nil
        }
    }
    var size: Int {
        switch self { case .i8, .u8: return 1; case .i16, .u16: return 2; case .i32, .u32, .f32: return 4; case .f64: return 8 }
    }
}

private struct PLYProp { var name: String; var type: PLYType; var listCount: PLYType? }
private struct PLYElement { var name: String; var count: Int; var props: [PLYProp] = [] }

private func readPLY(_ t: PLYType, _ raw: UnsafeRawBufferPointer, _ o: Int, _ big: Bool) -> Double {
    switch t {
    case .i8: return Double(Int8(bitPattern: raw[o]))
    case .u8: return Double(raw[o])
    case .i16: let v = raw.loadUnaligned(fromByteOffset: o, as: UInt16.self); return Double(Int16(bitPattern: big ? UInt16(bigEndian: v) : UInt16(littleEndian: v)))
    case .u16: let v = raw.loadUnaligned(fromByteOffset: o, as: UInt16.self); return Double(big ? UInt16(bigEndian: v) : UInt16(littleEndian: v))
    case .i32: let v = raw.loadUnaligned(fromByteOffset: o, as: UInt32.self); return Double(Int32(bitPattern: big ? UInt32(bigEndian: v) : UInt32(littleEndian: v)))
    case .u32: let v = raw.loadUnaligned(fromByteOffset: o, as: UInt32.self); return Double(big ? UInt32(bigEndian: v) : UInt32(littleEndian: v))
    case .f32: let v = raw.loadUnaligned(fromByteOffset: o, as: UInt32.self); return Double(Float(bitPattern: big ? UInt32(bigEndian: v) : UInt32(littleEndian: v)))
    case .f64: let v = raw.loadUnaligned(fromByteOffset: o, as: UInt64.self); return Double(bitPattern: big ? UInt64(bigEndian: v) : UInt64(littleEndian: v))
    }
}

func parsePLY(_ url: URL) throws -> [RawMesh] {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard let endR = data.range(of: Data("end_header".utf8)), endR.lowerBound < 200_000 else { throw LoadError.invalid("en-tête PLY absent") }
    var bodyStart = endR.upperBound
    while bodyStart < data.count, data[bodyStart] != 10 { bodyStart += 1 }
    bodyStart += 1
    let header = String(decoding: data[..<endR.lowerBound], as: UTF8.self)
    var format = "ascii"
    var elements: [PLYElement] = []
    for raw in header.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let t = raw.split(separator: " ").map(String.init)
        guard let k = t.first else { continue }
        if k == "format", t.count > 1 { format = t[1] }
        else if k == "element", t.count >= 3 { elements.append(PLYElement(name: t[1], count: Int(t[2]) ?? 0)) }
        else if k == "property", !elements.isEmpty {
            if t.count >= 5, t[1] == "list", let ct = PLYType(t[2]), let it = PLYType(t[3]) {
                elements[elements.count - 1].props.append(PLYProp(name: t[4], type: it, listCount: ct))
            } else if t.count >= 3, let ty = PLYType(t[1]) {
                elements[elements.count - 1].props.append(PLYProp(name: t[2], type: ty, listCount: nil))
            }
        }
    }
    let binary = format.hasPrefix("binary")
    let big = format == "binary_big_endian"

    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var colors: [SIMD4<Float>] = []
    var hasNormals = false, hasColors = false
    var tris: [UInt32] = []

    func role(_ n: String) -> Int {
        switch n {
        case "x": return 0; case "y": return 1; case "z": return 2
        case "nx": return 3; case "ny": return 4; case "nz": return 5
        case "red", "r": return 6; case "green", "g": return 7; case "blue", "b": return 8; case "alpha", "a": return 9
        default: return -1
        }
    }
    func handleVertex(_ v: [Double], _ roles: [Int], _ colorScale: [Double]) {
        var p = SIMD3<Float>(0, 0, 0), n = SIMD3<Float>(0, 0, 0), c = SIMD4<Float>(1, 1, 1, 1)
        for (i, r) in roles.enumerated() {
            let val = Float(v[i])
            switch r {
            case 0: p.x = val; case 1: p.y = val; case 2: p.z = val
            case 3: n.x = val; case 4: n.y = val; case 5: n.z = val
            case 6: c.x = Float(v[i] / colorScale[i]); case 7: c.y = Float(v[i] / colorScale[i])
            case 8: c.z = Float(v[i] / colorScale[i])
            default: break
            }
        }
        positions.append(p)
        if hasNormals { normals.append(n) }
        if hasColors { colors.append(c) }
    }
    func addFace(_ idx: [Int]) {
        if idx.count < 3 { return }
        for i in 1..<(idx.count - 1) { tris.append(UInt32(idx[0])); tris.append(UInt32(idx[i])); tris.append(UInt32(idx[i + 1])) }
    }

    if binary {
        try data.withUnsafeBytes { raw in
            var o = bodyStart
            for el in elements {
                let isVertex = el.name == "vertex", isFace = el.name == "face"
                let roles = el.props.map { $0.listCount == nil ? role($0.name) : -1 }
                if isVertex {
                    hasNormals = roles.contains(3) && roles.contains(4) && roles.contains(5)
                    hasColors = roles.contains(6) && roles.contains(7) && roles.contains(8)
                    positions.reserveCapacity(el.count)
                }
                let scales = el.props.map { ($0.type == .u8 || $0.type == .i8) ? 255.0 : ($0.type == .u16 ? 65535.0 : 1.0) }
                var vals = [Double](repeating: 0, count: el.props.count)
                for _ in 0..<el.count {
                    var face: [Int] = []
                    for (pi, pr) in el.props.enumerated() {
                        if let ct = pr.listCount {
                            if o + ct.size > raw.count { throw LoadError.invalid("PLY tronqué") }
                            let n = Int(readPLY(ct, raw, o, big)); o += ct.size
                            if o + n * pr.type.size > raw.count { throw LoadError.invalid("PLY tronqué") }
                            if isFace && (pr.name == "vertex_indices" || pr.name == "vertex_index") {
                                face.reserveCapacity(n)
                                for k in 0..<n { face.append(Int(readPLY(pr.type, raw, o + k * pr.type.size, big))) }
                            }
                            o += n * pr.type.size
                        } else {
                            if o + pr.type.size > raw.count { throw LoadError.invalid("PLY tronqué") }
                            vals[pi] = readPLY(pr.type, raw, o, big); o += pr.type.size
                        }
                    }
                    if isVertex { handleVertex(vals, roles, scales) }
                    else if isFace { addFace(face) }
                }
            }
        }
    } else {
        let bytes = try readTextBuffer(url)
        var ei = 0
        var left = elements.first?.count ?? 0
        var roles: [Int] = [], scales: [Double] = []
        var vertexReady = false
        forEachLine(bytes, from: bodyStart) { sc in
            while ei < elements.count && left == 0 { ei += 1; left = ei < elements.count ? elements[ei].count : 0 }
            if ei >= elements.count { return }
            let el = elements[ei]
            left -= 1
            if el.name == "vertex" {
                if !vertexReady {
                    roles = el.props.map { $0.listCount == nil ? role($0.name) : -1 }
                    scales = el.props.map { ($0.type == .u8 || $0.type == .i8) ? 255.0 : 1.0 }
                    hasNormals = roles.contains(3) && roles.contains(4) && roles.contains(5)
                    hasColors = roles.contains(6) && roles.contains(7) && roles.contains(8)
                    vertexReady = true
                }
                var vals = [Double](repeating: 0, count: el.props.count)
                for (pi, pr) in el.props.enumerated() {
                    if pr.listCount != nil { let n = Int(sc.double() ?? 0); for _ in 0..<n { _ = sc.double() } }
                    else { vals[pi] = sc.double() ?? 0 }
                }
                handleVertex(vals, roles, scales)
            } else if el.name == "face" {
                var face: [Int] = []
                for pr in el.props {
                    if pr.listCount != nil {
                        let n = Int(sc.double() ?? 0)
                        var l: [Int] = []
                        for _ in 0..<n { l.append(Int(sc.double() ?? 0)) }
                        if pr.name == "vertex_indices" || pr.name == "vertex_index" { face = l }
                    } else { _ = sc.double() }
                }
                addFace(face)
            }
        }
    }
    if positions.isEmpty { throw LoadError.empty }
    var m = RawMesh()
    m.positions = positions
    m.colors = hasColors ? colors : nil
    if tris.isEmpty { m.isPointCloud = true; return [m] }
    let maxIdx = UInt32(positions.count)
    if tris.contains(where: { $0 >= maxIdx }) { throw LoadError.invalid("indices PLY invalides") }
    m.cornerPos = tris
    if hasNormals { m.cornerNormals = tris.map { normals[Int($0)] } }
    return [m]
}

// MARK: - 3MF (archive zip + XML)

private struct ZipEntry { var name: String; var method: Int; var compSize: Int; var size: Int; var offset: Int }

private func readZip(_ data: Data) -> [ZipEntry] {
    func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    var eocd = -1
    var i = data.count - 22
    let lowest = max(0, data.count - 65_557)
    while i >= lowest {
        if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 5, data[i + 3] == 6 { eocd = i; break }
        i -= 1
    }
    if eocd < 0 { return [] }
    let n = u16(eocd + 10)
    var o = u32(eocd + 16)
    var out: [ZipEntry] = []
    for _ in 0..<n {
        guard o + 46 <= data.count, u32(o) == 0x02014b50 else { break }
        let method = u16(o + 10), cs = u32(o + 20), us = u32(o + 24)
        let nl = u16(o + 28), el = u16(o + 30), cl = u16(o + 32), lo = u32(o + 42)
        let name = String(decoding: data[(o + 46)..<(o + 46 + nl)], as: UTF8.self)
        out.append(ZipEntry(name: name, method: method, compSize: cs, size: us, offset: lo))
        o += 46 + nl + el + cl
    }
    return out
}

private func extract(_ e: ZipEntry, from data: Data) -> Data? {
    func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
    guard e.offset + 30 <= data.count else { return nil }
    let start = e.offset + 30 + u16(e.offset + 26) + u16(e.offset + 28)
    guard start + e.compSize <= data.count else { return nil }
    let comp = data[start..<(start + e.compSize)]
    if e.method == 0 { return Data(comp) }
    guard e.method == 8 else { return nil }
    var out = Data(count: e.size)
    let written = out.withUnsafeMutableBytes { dst -> Int in
        comp.withUnsafeBytes { src -> Int in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.size,
                                      src.bindMemory(to: UInt8.self).baseAddress!, e.compSize, nil, COMPRESSION_ZLIB)
        }
    }
    return written == e.size ? out : nil
}

private final class ThreeMFParser: NSObject, XMLParserDelegate {
    struct Obj { var positions: [SIMD3<Float>] = []; var tris: [UInt32] = []; var comps: [(Int, simd_float4x4)] = [] }
    var objects: [Int: Obj] = [:]
    var order: [Int] = []
    var items: [(Int, simd_float4x4)] = []
    var cur: Int?
    var inBuild = false

    static func matrix(_ s: String?) -> simd_float4x4 {
        guard let s = s else { return matrix_identity_float4x4 }
        let v = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).compactMap { Float($0) }
        guard v.count == 12 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (SIMD4(v[0], v[1], v[2], 0), SIMD4(v[3], v[4], v[5], 0),
                                       SIMD4(v[6], v[7], v[8], 0), SIMD4(v[9], v[10], v[11], 1)))
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        let n = name.split(separator: ":").last.map(String.init) ?? name
        switch n {
        case "object": if let id = Int(a["id"] ?? "") { cur = id; objects[id] = Obj(); order.append(id) }
        case "vertex":
            if let c = cur, let x = Float(a["x"] ?? ""), let y = Float(a["y"] ?? ""), let z = Float(a["z"] ?? "") { objects[c]?.positions.append(SIMD3(x, y, z)) }
        case "triangle":
            if let c = cur, let v1 = UInt32(a["v1"] ?? ""), let v2 = UInt32(a["v2"] ?? ""), let v3 = UInt32(a["v3"] ?? "") { objects[c]?.tris += [v1, v2, v3] }
        case "component":
            if let c = cur, let id = Int(a["objectid"] ?? "") { objects[c]?.comps.append((id, ThreeMFParser.matrix(a["transform"]))) }
        case "build": inBuild = true
        case "item": if inBuild, let id = Int(a["objectid"] ?? "") { items.append((id, ThreeMFParser.matrix(a["transform"]))) }
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let n = name.split(separator: ":").last.map(String.init) ?? name
        if n == "object" { cur = nil } else if n == "build" { inBuild = false }
    }
}

func parse3MF(_ url: URL) throws -> [RawMesh] {
    let zip = try Data(contentsOf: url, options: .mappedIfSafe)
    let entries = readZip(zip)
    if entries.isEmpty { throw LoadError.invalid("archive 3MF illisible") }
    let models = entries.filter { $0.name.lowercased().hasSuffix(".model") }
    let main = models.first { $0.name.lowercased() == "3d/3dmodel.model" } ?? models.first
    guard let mainEntry = main else { throw LoadError.invalid("modèle 3D absent de l'archive") }

    var mesh = RawMesh()
    var combined: [SIMD3<Float>] = []
    var corners: [UInt32] = []

    func collect(_ p: ThreeMFParser) {
        func add(_ id: Int, _ m: simd_float4x4, _ depth: Int) {
            guard depth < 8, let o = p.objects[id] else { return }
            if !o.tris.isEmpty {
                let base = UInt32(combined.count)
                for v in o.positions { let t = m * SIMD4(v, 1); combined.append(SIMD3(t.x, t.y, t.z)) }
                for i in o.tris where Int(i) < o.positions.count { corners.append(base + i) }
                if corners.count % 3 != 0 { corners.removeLast(corners.count % 3) }
            }
            for (cid, cm) in o.comps { add(cid, m * cm, depth + 1) }
        }
        if p.items.isEmpty { for id in p.order { add(id, matrix_identity_float4x4, 0) } }
        else { for (id, m) in p.items { add(id, m, 0) } }
    }
    func parseModel(_ e: ZipEntry) {
        guard let d = extract(e, from: zip) else { return }
        let xp = XMLParser(data: d)
        let del = ThreeMFParser()
        xp.delegate = del
        xp.parse()
        collect(del)
    }
    parseModel(mainEntry)
    if corners.isEmpty { for e in models where e.name != mainEntry.name { parseModel(e) } }
    if corners.isEmpty { throw LoadError.empty }
    mesh.positions = combined
    mesh.cornerPos = corners
    return [mesh]
}
