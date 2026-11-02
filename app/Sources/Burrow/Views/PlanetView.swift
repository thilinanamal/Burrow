import AppKit
import SceneKit
import SwiftUI

enum PlanetKind: String, CaseIterable {
    case earth, moon, mercury, jupiter, sun, ice
}

/// Procedurally textured, slowly spinning planet. All textures are generated
/// at runtime from noise, so the app ships no third-party imagery.
struct PlanetView: NSViewRepresentable {
    var kind: PlanetKind
    var spinSeconds: Double = 90
    var tilt: Double = 0.25

    func makeNSView(context: Context) -> SCNView {
        // A zero-sized Metal drawable asserts, so start with a real frame;
        // SwiftUI resizes it right after.
        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 64, height: 64),
                           options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 24
        view.scene = makeScene()
        view.isPlaying = true
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 96
        let material = SCNMaterial()
        material.diffuse.contents = PlanetTexture.image(for: kind)
        material.diffuse.wrapS = .repeat
        if kind == .sun {
            material.lightingModel = .constant
            material.emission.contents = PlanetTexture.image(for: kind)
        } else {
            material.lightingModel = .lambert
        }
        material.specular.contents = NSColor.black
        sphere.materials = [material]

        let node = SCNNode(geometry: sphere)
        node.eulerAngles = SCNVector3(tilt, 0, 0.12)
        let spin = SCNAction.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: spinSeconds))
        node.runAction(spin)
        scene.rootNode.addChildNode(node)

        if kind != .sun {
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 1100
            key.light?.color = NSColor(white: 1, alpha: 1)
            key.eulerAngles = SCNVector3(-0.5, -0.7, 0)
            scene.rootNode.addChildNode(key)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 260
            ambient.light?.color = NSColor(calibratedRed: 0.75, green: 0.8, blue: 1, alpha: 1)
            scene.rootNode.addChildNode(ambient)
        }

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.position = SCNVector3(0, 0, 3.9)
        scene.rootNode.addChildNode(camera)
        return scene
    }
}

// MARK: - Procedural textures

enum PlanetTexture {
    private static var cache: [PlanetKind: NSImage] = [:]
    private static let lock = NSLock()

    static func image(for kind: PlanetKind) -> NSImage {
        lock.lock()
        if let cached = cache[kind] { lock.unlock(); return cached }
        lock.unlock()
        let image = render(kind)
        lock.lock()
        cache[kind] = image
        lock.unlock()
        return image
    }

    /// Warms the cache off the main thread so the first tab switch is smooth.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            for kind in PlanetKind.allCases { _ = image(for: kind) }
        }
    }

    private static func render(_ kind: PlanetKind) -> NSImage {
        let width = 1024, height = 512
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let craters = kind == .moon || kind == .mercury ? makeCraters(seed: kind == .moon ? 7 : 19, count: 140) : []

        for y in 0..<height {
            let lat = (0.5 - (Double(y) + 0.5) / Double(height)) * .pi
            let cosLat = cos(lat), sinLat = sin(lat)
            for x in 0..<width {
                let lon = (Double(x) + 0.5) / Double(width) * 2 * .pi
                let p = SIMD3(cosLat * cos(lon), sinLat, cosLat * sin(lon))
                let c = color(kind, p: p, lat: lat, craters: craters)
                let i = (y * width + x) * 4
                pixels[i] = UInt8(max(0, min(255, c.x * 255)))
                pixels[i + 1] = UInt8(max(0, min(255, c.y * 255)))
                pixels[i + 2] = UInt8(max(0, min(255, c.z * 255)))
                pixels[i + 3] = 255
            }
        }

        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    private typealias V3 = SIMD3<Double>

    private static func mix(_ a: V3, _ b: V3, _ t: Double) -> V3 { a + (b - a) * max(0, min(1, t)) }
    private static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    private static func color(_ kind: PlanetKind, p: V3, lat: Double, craters: [(V3, Double)]) -> V3 {
        switch kind {
        case .earth:
            let continents = Noise.fbm(p * 1.6 + V3(3.1, 1.7, 0.4), octaves: 6)
            let detail = Noise.fbm(p * 6 + V3(9, 2, 5), octaves: 4)
            let h = continents * 0.85 + detail * 0.15
            var c: V3
            if h < 0.56 {
                let depth = smooth(0.30, 0.56, h)
                c = mix(V3(0.05, 0.16, 0.42), V3(0.13, 0.36, 0.68), depth)
            } else {
                let land = smooth(0.56, 0.74, h)
                let dry = Noise.fbm(p * 3 + V3(1, 8, 3), octaves: 3)
                let green = mix(V3(0.20, 0.42, 0.18), V3(0.42, 0.50, 0.26), land)
                let desert = mix(V3(0.72, 0.55, 0.33), V3(0.62, 0.36, 0.20), land)
                c = mix(green, desert, smooth(0.5, 0.65, dry) * (1 - abs(lat) / 1.2))
            }
            let polar = smooth(1.12, 1.28, abs(lat) + (Noise.fbm(p * 4, octaves: 3) - 0.5) * 0.2)
            c = mix(c, V3(0.93, 0.95, 0.98), polar)
            let clouds = smooth(0.55, 0.78, Noise.fbm(p * 2.6 + V3(5, 5, 5), octaves: 6))
            return mix(c, V3(0.97, 0.98, 1.0), clouds * 0.85)

        case .moon, .mercury:
            let base = Noise.fbm(p * 2.2, octaves: 6)
            let fine = Noise.fbm(p * 14, octaves: 3)
            var shade = 0.42 + (base - 0.5) * 0.45 + (fine - 0.5) * 0.12
            let maria = smooth(0.52, 0.62, Noise.fbm(p * 1.3 + V3(2, 0, 7), octaves: 4))
            shade -= maria * 0.12
            for (center, radius) in craters {
                let d = simd_length_compat(p - center)
                if d < radius * 1.25 {
                    let r = d / radius
                    if r < 0.85 { shade -= 0.07 * (1 - r) }
                    else if r < 1.15 { shade += 0.10 * (1 - abs(r - 1) / 0.15) }
                }
            }
            let tint = kind == .moon ? V3(1.0, 1.0, 1.02) : V3(1.04, 0.99, 0.94)
            return V3(repeating: shade) * tint

        case .jupiter:
            let warp = Noise.fbm(p * 3 + V3(1, 2, 3), octaves: 5)
            let bands = sin(lat * 14 + (warp - 0.5) * 3.2)
            let fine = Noise.fbm(p * V3(4, 30, 4), octaves: 4)
            let light = V3(0.90, 0.84, 0.74)
            let tan = V3(0.78, 0.60, 0.42)
            let rust = V3(0.62, 0.38, 0.24)
            var c = mix(light, tan, smooth(-0.4, 0.6, bands))
            c = mix(c, rust, smooth(0.55, 0.95, bands) * 0.7)
            c = c * (0.92 + fine * 0.16)
            // Storm oval in the southern band.
            let storm = V3(cos(-0.38) * cos(1.2), sin(-0.38), cos(-0.38) * sin(1.2))
            let d = simd_length_compat((p - storm) * V3(1, 1.9, 1))
            c = mix(c, V3(0.78, 0.40, 0.28), smooth(0.20, 0.10, d))
            return c

        case .sun:
            let t = Noise.fbm(p * 3.5, octaves: 6)
            let cells = Noise.fbm(p * 18, octaves: 3)
            let heat = t * 0.7 + cells * 0.3
            var c = mix(V3(0.85, 0.25, 0.04), V3(1.0, 0.62, 0.12), smooth(0.35, 0.6, heat))
            c = mix(c, V3(1.0, 0.92, 0.55), smooth(0.62, 0.8, heat))
            return c

        case .ice:
            let n = Noise.fbm(p * 3, octaves: 5)
            return mix(V3(0.55, 0.70, 0.82), V3(0.88, 0.94, 0.98), n)
        }
    }

    private static func simd_length_compat(_ v: V3) -> Double { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }

    private static func makeCraters(seed: UInt64, count: Int) -> [(V3, Double)] {
        var rng = SplitMix(seed: seed)
        return (0..<count).map { _ in
            let u = rng.nextDouble() * 2 - 1
            let theta = rng.nextDouble() * 2 * .pi
            let r = (1 - u * u).squareRoot()
            let center = V3(r * cos(theta), u, r * sin(theta))
            let radius = 0.02 + pow(rng.nextDouble(), 3) * 0.16
            return (center, radius)
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// 3D value noise with fractal sum, sampled on the sphere so textures have no seam.
enum Noise {
    private static func hash(_ x: Int, _ y: Int, _ z: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 374761393 &+ y &* 668265263 &+ z &* 2147483647))
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Double(h & 0xFFFF) / 65535.0
    }

    static func value(_ p: SIMD3<Double>) -> Double {
        let xi = Int(floor(p.x)), yi = Int(floor(p.y)), zi = Int(floor(p.z))
        let xf = p.x - floor(p.x), yf = p.y - floor(p.y), zf = p.z - floor(p.z)
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf), w = zf * zf * (3 - 2 * zf)
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let c000 = hash(xi, yi, zi), c100 = hash(xi + 1, yi, zi)
        let c010 = hash(xi, yi + 1, zi), c110 = hash(xi + 1, yi + 1, zi)
        let c001 = hash(xi, yi, zi + 1), c101 = hash(xi + 1, yi, zi + 1)
        let c011 = hash(xi, yi + 1, zi + 1), c111 = hash(xi + 1, yi + 1, zi + 1)
        let x00 = lerp(c000, c100, u), x10 = lerp(c010, c110, u)
        let x01 = lerp(c001, c101, u), x11 = lerp(c011, c111, u)
        return lerp(lerp(x00, x10, v), lerp(x01, x11, v), w)
    }

    static func fbm(_ p: SIMD3<Double>, octaves: Int) -> Double {
        var sum = 0.0, amp = 0.5, freq = 1.0, norm = 0.0
        for _ in 0..<octaves {
            sum += value(p * freq) * amp
            norm += amp
            amp *= 0.5
            freq *= 2.03
        }
        return sum / norm
    }
}
