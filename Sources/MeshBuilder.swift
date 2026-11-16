import Foundation
import SceneKit
import AppKit
import simd

/// Maillage brut lu depuis un fichier, avant création de la géométrie SceneKit.
struct RawMesh {
    var positions: [SIMD3<Float>] = []
    var colors: [SIMD4<Float>]? = nil            // une couleur par position
    var uvs: [SIMD2<Float>] = []
    var cornerPos: [UInt32] = []                  // 3 par triangle
    var cornerUV: [UInt32]? = nil                 // 3 par triangle (UInt32.max = aucun)
    var cornerNormals: [SIMD3<Float>]? = nil      // 3 par triangle, si le fichier en fournit
    var color: SIMD4<Float>? = nil                // couleur du matériau
    var texture: URL? = nil
    var isPointCloud = false
}

/// Fusionne les sommets strictement identiques (utile pour le STL, qui répète chaque sommet).
func weld(_ unwelded: [SIMD3<Float>]) -> (positions: [SIMD3<Float>], corners: [UInt32]) {
    var map = [SIMD3<UInt32>: UInt32](minimumCapacity: unwelded.count / 2)
    var positions: [SIMD3<Float>] = []
    positions.reserveCapacity(unwelded.count / 2)
    var corners = [UInt32](repeating: 0, count: unwelded.count)
    for (i, p) in unwelded.enumerated() {
        let q = p + SIMD3<Float>(repeating: 0)          // -0.0 devient +0.0
        let key = SIMD3<UInt32>(q.x.bitPattern, q.y.bitPattern, q.z.bitPattern)
        if let idx = map[key] { corners[i] = idx } else {
            let idx = UInt32(positions.count)
            map[key] = idx
            positions.append(p)
            corners[i] = idx
        }
    }
    return (positions, corners)
}

private func makeSource<T>(_ array: [T], _ semantic: SCNGeometrySource.Semantic, comps: Int) -> SCNGeometrySource {
    let data = array.withUnsafeBufferPointer { Data(buffer: $0) }
    return SCNGeometrySource(data: data, semantic: semantic, vectorCount: array.count, usesFloatComponents: true,
                             componentsPerVector: comps, bytesPerComponent: 4, dataOffset: 0,
                             dataStride: MemoryLayout<T>.stride)
}

let defaultClayColor = NSColor(srgbRed: 0.80, green: 0.83, blue: 0.90, alpha: 1)

/// Transforme un maillage brut en géométrie SceneKit avec des normales lissées
/// (les arêtes vives restent vives : angle de pli de 50°).
func buildGeometry(_ m: RawMesh) -> (geometry: SCNGeometry, triangles: Int)? {
    if m.isPointCloud { return buildPointCloud(m) }
    let triCount = m.cornerPos.count / 3
    if triCount == 0 || m.positions.isEmpty { return nil }
    let pos = m.positions
    let cp = m.cornerPos

    // Normales de face (pondérées par l'aire)
    var faceN = [SIMD3<Float>](repeating: .zero, count: triCount)
    var faceU = [SIMD3<Float>](repeating: .zero, count: triCount)
    for t in 0..<triCount {
        let a = pos[Int(cp[3 * t])], b = pos[Int(cp[3 * t + 1])], c = pos[Int(cp[3 * t + 2])]
        let n = simd_cross(b - a, c - a)
        faceN[t] = n
        let l = simd_length(n)
        faceU[t] = l > 1e-20 ? n / l : .zero
    }

    // Normales par coin
    var cornerN: [SIMD3<Float>]
    if let given = m.cornerNormals, given.count == cp.count {
        cornerN = given
    } else {
        // adjacence sommet -> faces (format CSR)
        var offsets = [Int32](repeating: 0, count: pos.count + 1)
        for c in cp { offsets[Int(c) + 1] += 1 }
        for i in 0..<pos.count { offsets[i + 1] += offsets[i] }
        var fill = offsets
        var adj = [Int32](repeating: 0, count: cp.count)
        for t in 0..<triCount {
            for k in 0..<3 {
                let v = Int(cp[3 * t + k])
                adj[Int(fill[v])] = Int32(t); fill[v] += 1
            }
        }
        let cosCrease: Float = 0.6428       // cos(50°)
        cornerN = [SIMD3<Float>](repeating: .zero, count: cp.count)
        for t in 0..<triCount {
            let fu = faceU[t]
            for k in 0..<3 {
                let v = Int(cp[3 * t + k])
                var sum = SIMD3<Float>.zero
                for j in Int(offsets[v])..<Int(offsets[v + 1]) {
                    let g = Int(adj[j])
                    if simd_dot(fu, faceU[g]) > cosCrease { sum += faceN[g] }
                }
                cornerN[3 * t + k] = sum
            }
        }
    }

    // Création des sommets de sortie : un sommet est réutilisé s'il a même position, même UV et même normale.
    var outPos: [SIMD3<Float>] = []; outPos.reserveCapacity(pos.count)
    var outN: [SIMD3<Float>] = []; outN.reserveCapacity(pos.count)
    var outUV: [SIMD2<Float>] = []
    var outUVIdx: [UInt32] = []
    var outCol: [SIMD4<Float>] = []
    var next: [Int32] = []; next.reserveCapacity(pos.count)
    var head = [Int32](repeating: -1, count: pos.count)
    var indices = [UInt32](); indices.reserveCapacity(cp.count)
    let hasUV = m.cornerUV != nil && !m.uvs.isEmpty
    let hasCol = m.colors != nil

    for c in 0..<cp.count {
        let p = Int(cp[c])
        var n = cornerN[c]
        let l = simd_length(n)
        n = l > 1e-20 ? n / l : SIMD3<Float>(0, 1, 0)
        let u: UInt32 = hasUV ? m.cornerUV![c] : UInt32.max
        var j = head[p]
        var found: Int32 = -1
        while j >= 0 {
            if outUVIdx[Int(j)] == u && simd_dot(outN[Int(j)], n) > 0.9995 { found = j; break }
            j = next[Int(j)]
        }
        if found < 0 {
            found = Int32(outPos.count)
            outPos.append(pos[p]); outN.append(n); outUVIdx.append(u)
            if hasUV { outUV.append(u == UInt32.max ? .zero : SIMD2<Float>(m.uvs[Int(u)].x, 1 - m.uvs[Int(u)].y)) }
            if hasCol { outCol.append(m.colors![p]) }
            next.append(head[p]); head[p] = found
        }
        indices.append(UInt32(found))
    }

    var sources = [makeSource(outPos, .vertex, comps: 3), makeSource(outN, .normal, comps: 3)]
    if hasUV { sources.append(makeSource(outUV, .texcoord, comps: 2)) }
    if hasCol { sources.append(makeSource(outCol, .color, comps: 4)) }
    let element = SCNGeometryElement(data: indices.withUnsafeBufferPointer { Data(buffer: $0) },
                                     primitiveType: .triangles, primitiveCount: indices.count / 3, bytesPerIndex: 4)
    let geo = SCNGeometry(sources: sources, elements: [element])

    let mat = SCNMaterial()
    mat.lightingModel = .blinn
    mat.isDoubleSided = true
    mat.specular.contents = NSColor(white: 0.35, alpha: 1)
    mat.shininess = 0.25
    if let tex = m.texture, hasUV, let img = NSImage(contentsOf: tex) {
        mat.diffuse.contents = img
        mat.diffuse.wrapS = .repeat; mat.diffuse.wrapT = .repeat
    } else if let c = m.color {
        mat.diffuse.contents = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    } else if hasCol {
        mat.diffuse.contents = NSColor.white
    } else {
        mat.diffuse.contents = defaultClayColor
    }
    geo.materials = [mat]
    return (geo, triCount)
}

private func buildPointCloud(_ m: RawMesh) -> (SCNGeometry, Int)? {
    if m.positions.isEmpty { return nil }
    var sources = [makeSource(m.positions, .vertex, comps: 3)]
    if let c = m.colors { sources.append(makeSource(c, .color, comps: 4)) }
    let idx = (0..<UInt32(m.positions.count)).map { $0 }
    let element = SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) },
                                     primitiveType: .point, primitiveCount: idx.count, bytesPerIndex: 4)
    element.pointSize = 2
    element.minimumPointScreenSpaceRadius = 1.2
    element.maximumPointScreenSpaceRadius = 4
    let geo = SCNGeometry(sources: sources, elements: [element])
    let mat = SCNMaterial()
    mat.lightingModel = .constant
    mat.diffuse.contents = m.colors != nil ? NSColor.white : NSColor(srgbRed: 0.35, green: 0.45, blue: 0.75, alpha: 1)
    geo.materials = [mat]
    return (geo, 0)
}
