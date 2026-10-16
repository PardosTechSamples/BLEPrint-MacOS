import CoreGraphics
import Foundation

/// 8-bit grayscale bitmap (0 = black, 255 = white), row-major. The common currency between
/// rendering, preview and the printer encoders.
public struct GrayImage: Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: UInt8 = 255) {
        self.width = max(1, width)
        self.height = max(1, height)
        pixels = [UInt8](repeating: fill, count: self.width * self.height)
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    public func isDark(_ x: Int, _ y: Int, threshold: UInt8 = 128) -> Bool {
        self[x, y] < threshold
    }

    /// Paste `other` with its top-left corner at (x, y), clipped.
    public mutating func paste(_ other: GrayImage, x: Int, y: Int) {
        for sy in 0..<other.height {
            let ty = y + sy
            guard ty >= 0, ty < height else { continue }
            for sx in 0..<other.width {
                let tx = x + sx
                guard tx >= 0, tx < width else { continue }
                self[tx, ty] = other[sx, sy]
            }
        }
    }

    public mutating func fillRect(x: Int, y: Int, w: Int, h: Int, value: UInt8 = 0) {
        for yy in max(0, y)..<min(height, y + h) {
            for xx in max(0, x)..<min(width, x + w) { self[xx, yy] = value }
        }
    }

    public func crop(x: Int, y: Int, w: Int, h: Int) -> GrayImage {
        var out = GrayImage(width: w, height: h)
        out.paste(self, x: -x, y: -y)
        return out
    }

    /// Rotate 90° counter-clockwise (like PIL's rotate(90, expand=True)).
    public func rotatedCCW() -> GrayImage {
        var out = GrayImage(width: height, height: width)
        for y in 0..<height {
            for x in 0..<width { out[y, width - 1 - x] = self[x, y] }
        }
        return out
    }

    /// Rotate 90° clockwise (like PIL's rotate(-90, expand=True)).
    public func rotatedCW() -> GrayImage {
        var out = GrayImage(width: height, height: width)
        for y in 0..<height {
            for x in 0..<width { out[height - 1 - y, x] = self[x, y] }
        }
        return out
    }

    /// Bounding box of pixels darker than the threshold, or nil if blank.
    public func inkBounds(threshold: UInt8 = 128) -> (x: Int, y: Int, w: Int, h: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where pixels[row + x] < threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    public var cgImage: CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Read a CGImage into grayscale (white background behind transparency).
    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let buf = base.bindMemory(to: UInt8.self, capacity: w * h)
        self.init(width: w, height: h, pixels: Array(UnsafeBufferPointer(start: buf, count: w * h)))
    }
}
