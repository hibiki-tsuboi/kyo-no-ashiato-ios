import Testing
import CoreLocation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
@testable import KyoNoAshiato

@Suite struct MediaLocationImageTests {

    @Test func extractsCoordinateFromNorthEastImage() {
        let data = makeJPEG(gps: GPS(lat: 35.6895, lon: 139.6917, latRef: "N", lonRef: "E"))
        let coord = MediaLocation.extract(fromImage: data)
        #expect(coord?.latitude == 35.6895)
        #expect(coord?.longitude == 139.6917)
    }

    @Test func flipsSignForSouthAndWestRefs() {
        // EXIF は緯度経度を絶対値で保存し、Ref で南/西を表す。符号反転されることを確認。
        let data = makeJPEG(gps: GPS(lat: 33.8688, lon: 151.2093, latRef: "S", lonRef: "W"))
        let coord = MediaLocation.extract(fromImage: data)
        #expect(coord?.latitude == -33.8688)
        #expect(coord?.longitude == -151.2093)
    }

    @Test func returnsNilWhenNoGPSPresent() {
        let data = makeJPEG(gps: nil)
        let coord = MediaLocation.extract(fromImage: data)
        #expect(coord == nil)
    }

    @Test func defaultsToNorthEastWhenRefsMissing() {
        // 仕様外だが Ref が欠落した場合に北半球・東半球扱いで読めることを確認しておく。
        let data = makeJPEG(gps: GPS(lat: 10.0, lon: 20.0, latRef: nil, lonRef: nil))
        let coord = MediaLocation.extract(fromImage: data)
        #expect(coord?.latitude == 10.0)
        #expect(coord?.longitude == 20.0)
    }
}

@Suite struct MediaLocationISO6709Tests {

    @Test func parsesBasicForm() {
        let coord = MediaLocation.parseISO6709("+35.6895+139.6917/")
        #expect(coord?.latitude == 35.6895)
        #expect(coord?.longitude == 139.6917)
    }

    @Test func ignoresAltitudeSuffix() {
        // 高度が末尾に続くパターン。緯度経度のみ拾えれば OK。
        let coord = MediaLocation.parseISO6709("+35.6895+139.6917+12.300/")
        #expect(coord?.latitude == 35.6895)
        #expect(coord?.longitude == 139.6917)
    }

    @Test func parsesNegativeSigns() {
        let coord = MediaLocation.parseISO6709("-33.8688-151.2093/")
        #expect(coord?.latitude == -33.8688)
        #expect(coord?.longitude == -151.2093)
    }

    @Test func returnsNilForGarbageInput() {
        #expect(MediaLocation.parseISO6709("hello") == nil)
    }
}

// MARK: - Fixtures

private struct GPS {
    let lat: Double
    let lon: Double
    let latRef: String?
    let lonRef: String?
}

private func makeJPEG(gps: GPS?) -> Data {
    let cgImage = makeSolidImage()

    var properties: [CFString: Any] = [:]
    if let gps {
        var gpsDict: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(gps.lat),
            kCGImagePropertyGPSLongitude: abs(gps.lon),
        ]
        if let latRef = gps.latRef {
            gpsDict[kCGImagePropertyGPSLatitudeRef] = latRef
        }
        if let lonRef = gps.lonRef {
            gpsDict[kCGImagePropertyGPSLongitudeRef] = lonRef
        }
        properties[kCGImagePropertyGPSDictionary] = gpsDict
    }

    let buffer = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        buffer as CFMutableData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        Issue.record("failed to create CGImageDestination")
        return Data()
    }
    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    _ = CGImageDestinationFinalize(destination)
    return buffer as Data
}

private func makeSolidImage() -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: 4,
        height: 4,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    )!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    return context.makeImage()!
}
