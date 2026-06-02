import AVFoundation
import CoreLocation
import Foundation
import ImageIO

/// 写真または動画から撮影地点（緯度経度）だけを取り出す。
/// EXIF / ISO 6709 が無ければ nil。自動配置のフォールバック判断に使う。
enum MediaLocation {
    /// 写真の Data から EXIF GPS を取り出す。
    /// 渡す Data は EXIF を保ったオリジナルである必要がある（リサイズ後の JPEG は GPS が落ちうる）。
    static func extract(fromImage data: Data) -> CLLocationCoordinate2D? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
            let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
            let lon = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return nil }

        // EXIF は緯度経度を絶対値で保存し、Ref で南/西半球を表す。ここで符号を戻す。
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
        return CLLocationCoordinate2D(
            latitude: latRef == "S" ? -lat : lat,
            longitude: lonRef == "W" ? -lon : lon
        )
    }

    /// 動画の AVAsset から ISO 6709 形式の位置情報を取り出す。
    /// Apple 端末で撮影した動画は `commonMetadata` の `commonKeyLocation` に
    /// `"+35.6895+139.6917/"` や `"+35.6895+139.6917+12.300/"` といった文字列で入る。
    static func extract(fromVideo asset: AVAsset) async -> CLLocationCoordinate2D? {
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyLocation {
            if let string = try? await item.load(.stringValue),
               let coord = parseISO6709(string) {
                return coord
            }
        }
        return nil
    }

    /// ISO 6709 の符号付き 10 進数表記から最初の (緯度, 経度) ペアを取り出す。
    /// 高度や CRS が後続するパターンもあるが先頭 2 つだけを採用する。
    /// テスト用に internal で露出している。
    static func parseISO6709(_ string: String) -> CLLocationCoordinate2D? {
        let pattern = #"([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard
            let match = regex.firstMatch(in: string, range: range),
            let latRange = Range(match.range(at: 1), in: string),
            let lonRange = Range(match.range(at: 2), in: string),
            let lat = Double(string[latRange]),
            let lon = Double(string[lonRange])
        else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
