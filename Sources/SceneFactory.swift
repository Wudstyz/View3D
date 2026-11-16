import Foundation
import SceneKit
import AppKit
import simd

let viewerBackground = NSColor(srgbRed: 0.115, green: 0.125, blue: 0.155, alpha: 1)

/// Scène prête à être affichée : modèle centré, mis à l'échelle, éclairé.
final class PreparedScene {
    let id = UUID()
    let scene = SCNScene()
    let radius: Float
    let distance: Float
    let fov: CGFloat = 35

    init(model: LoadedModel, zUp: Bool) {
        let pivot = SCNNode()
        let content = model.node.clone()
        content.eulerAngles.x = zUp ? -.pi / 2 : 0
        pivot.addChildNode(content)
        // Bornes calculées d'après la géométrie réelle (fiable même pour les scènes USD/DAE avec transformations)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        pivot.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let w = node.convertPosition(SCNVector3(x, y, z), to: pivot)
                let v = SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z))
                lo = simd_min(lo, v); hi = simd_max(hi, v)
            } } }
        }
        if lo.x > hi.x { lo = SIMD3(-1, -1, -1); hi = SIMD3(1, 1, 1) }
        let ext = hi - lo
        let maxDim = max(ext.max(), 1e-6)
        let s = 2 / maxDim
        let center = (lo + hi) / 2
        pivot.scale = SCNVector3(CGFloat(s), CGFloat(s), CGFloat(s))
        pivot.position = SCNVector3(CGFloat(-center.x * s), CGFloat(-center.y * s), CGFloat(-center.z * s))
        scene.rootNode.addChildNode(pivot)
        scene.background.contents = viewerBackground

        radius = max(0.5 * simd_length(ext) * s, 0.2)
        distance = radius / Float(sin(Double(fov) * .pi / 360)) * 1.08

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 380
        ambient.light!.color = NSColor(white: 1, alpha: 1)
        scene.rootNode.addChildNode(ambient)
    }

    /// Crée une caméra (avec ses lumières attachées, qui suivent le point de vue).
    func makeCamera() -> SCNNode {
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera!.fieldOfView = fov
        cam.camera!.zNear = Double(max(distance - radius * 3, 0.01) * 0.1)
        cam.camera!.zFar = Double(distance + radius * 6)
        let d = CGFloat(distance)
        cam.position = SCNVector3(d * 0.52, d * 0.40, d * 0.75)
        cam.look(at: SCNVector3(0, 0, 0))

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 950
        key.eulerAngles = SCNVector3(-0.75, 0.6, 0)
        cam.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .directional
        fill.light!.intensity = 260
        fill.eulerAngles = SCNVector3(0.35, -0.9, 0)
        cam.addChildNode(fill)
        return cam
    }
}

/// Rend les vignettes de la bibliothèque (hors écran).
@MainActor
final class ThumbnailRenderer {
    static let shared = ThumbnailRenderer()
    private let renderer: SCNRenderer

    private init() {
        renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.autoenablesDefaultLighting = false
    }

    func render(model: LoadedModel, zUp: Bool, size: CGSize = CGSize(width: 640, height: 480)) -> NSImage? {
        let prepared = PreparedScene(model: model, zUp: zUp)
        let cam = prepared.makeCamera()
        prepared.scene.rootNode.addChildNode(cam)
        renderer.scene = prepared.scene
        renderer.pointOfView = cam
        let img = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        renderer.scene = nil
        return img
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
