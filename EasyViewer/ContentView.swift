//
//  ContentView.swift
//  EasyViewer
//
//  Created by ZhouHang on 2026/7/16.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import ImageIO
import Accelerate

struct ContentView: View {
    @State private var droppedImage: NSImage?
    @State private var isTargeted = false
    @State private var currentURL: URL?
    @State private var folderImages: [URL] = []
    @State private var showInfoPanel = false
    @State private var actualSize = false
    @State private var zoomAnchor: ZoomAnchor?
    @State private var showFocusPoints = false
    @State private var focusPoints: [CGPoint] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            if let image = droppedImage {
                if actualSize {
                    // 1:1 像素显示，中键拖拽平移
                    PanScrollView(
                        image: image,
                        width: actualSizeWidth(image),
                        height: actualSizeHeight(image),
                        anchor: zoomAnchor,
                        focusPoints: showFocusPoints ? focusPoints : [],
                        onZoomOut: {
                            zoomAnchor = nil
                            actualSize = false
                        }
                    )
                } else {
                    FitImageView(image: image, focusPoints: showFocusPoints ? focusPoints : []) { anchor in
                        zoomAnchor = anchor
                        actualSize = true
                    }
                }
            } else {
                placeholderView
            }

            if showInfoPanel, !infoLines.isEmpty {
                infoPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        .overlay(
            Rectangle()
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    lineWidth: isTargeted ? 3 : 1,
                    antialiased: true
                )
        )
        .background(
            FileDropZone(isTargeted: $isTargeted) { url in
                loadImage(from: url)
            }
        )
        .background(
            CommandDeleteHandler {
                moveCurrentImageToTrash()
            }
        )
        .background(
            InfoPanelMouseHandler {
                showInfoPanel.toggle()
            }
        )
        .background(
            MouseWheelNavigationHandler { delta in
                navigate(delta: delta > 0 ? -1 : 1)
            }
        )
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            navigate(delta: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigate(delta: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            navigate(delta: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            navigate(delta: 1)
            return .handled
        }
        .onKeyPress(.pageUp) {
            navigate(delta: -1)
            return .handled
        }
        .onKeyPress(.pageDown) {
            navigate(delta: 1)
            return .handled
        }
        .onKeyPress("w") {
            navigate(delta: -1)
            return .handled
        }
        .onKeyPress("s") {
            navigate(delta: 1)
            return .handled
        }
        .onKeyPress("i") {
            showInfoPanel.toggle()
            return .handled
        }
        .onKeyPress("f") {
            toggleFocusPoints()
            return .handled
        }
        .onKeyPress(.space) {
            toggleActualSize()
            return .handled
        }
        .onKeyPress(.escape) {
            NSApplication.shared.terminate(nil)
            return .handled
        }
        .onAppear {
            isFocused = true
        }
        .onOpenURL { url in
            loadImage(from: url)
        }
        .navigationTitle(windowTitle)
    }

    private var windowTitle: String {
        guard let current = currentURL else { return "EasyViewer" }
        if folderImages.isEmpty {
            return current.lastPathComponent
        }
        let index = (imageIndex(for: current).map { $0 + 1 }) ?? 0
        return "\(current.lastPathComponent) — (\(index) / \(folderImages.count))"
    }

    private var infoPanel: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(infoLines, id: \.self) { item in
                GridRow {
                    Text(item.label)
                        .font(.system(.callout))
                    Text(item.value)
                        .font(.system(.title3, design: .monospaced))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // 1:1 像素显示：实际像素 / 屏幕缩放因子（Retina 为 2）
    private func actualSizeWidth(_ image: NSImage) -> CGFloat {
        let rep = image.representations.first
        let pixels = rep?.pixelsWide ?? Int(image.size.width)
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        return CGFloat(pixels) / scale
    }

    private func actualSizeHeight(_ image: NSImage) -> CGFloat {
        let rep = image.representations.first
        let pixels = rep?.pixelsHigh ?? Int(image.size.height)
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        return CGFloat(pixels) / scale
    }

    // 浮层显示的信息行：尺寸 + EXIF（按指定顺序，缺字段跳过）
    private var infoLines: [InfoItem] {
        var lines: [InfoItem] = []
        if let image = droppedImage {
            let rep = image.representations.first
            let w = rep?.pixelsWide ?? Int(image.size.width)
            let h = rep?.pixelsHigh ?? Int(image.size.height)
            lines.append(InfoItem(label: "图片尺寸", value: "\(w) × \(h)"))
        }
        lines.append(contentsOf: exifLines)
        return lines
    }

    // 读取 EXIF / 顶层 / GPS 属性，按固定顺序输出
    private var exifLines: [InfoItem] {
        guard let url = currentURL,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [] }
        let exif = props["{Exif}"] as? [String: Any]
        let tiff = props["{TIFF}"] as? [String: Any]
        let gps = props["{GPS}"] as? [String: Any]
        let exifAux = props["{ExifAux}"] as? [String: Any]
        let xmpLens = CGImageSourceCopyMetadataAtIndex(src, 0, nil).flatMap {
            CGImageMetadataCopyStringValueWithPath($0, nil, "aux:Lens" as CFString) as String?
        }
        // print("[EasyViewer] props 所有 key: \(props.keys.sorted())")
        // print("[EasyViewer] {ExifAux} 所有 key: \(exifAux?.keys.sorted() ?? [])")
        // print("[EasyViewer] {Exif} 所有 key: \(exif?.keys.sorted() ?? [])")
        // print("[EasyViewer] {tiff} 所有 key: \(tiff?.keys.sorted() ?? [])")


        var lines: [InfoItem] = []
        // 相机品牌（在 {TIFF} 里）
        if let v = tiff?["Make"] as? String ?? props["Make"] as? String {
            lines.append(InfoItem(label: "相机品牌", value: v))
        }
        // 相机型号（在 {TIFF} 里）
        if let v = tiff?["Model"] as? String ?? props["Model"] as? String {
            lines.append(InfoItem(label: "相机型号", value: v))
        }
        // 镜头品牌
        if let v = props["LensMake"] as? String ?? exif?["LensMake"] as? String {
            lines.append(InfoItem(label: "镜头品牌", value: v))
        }
        // 镜头型号（在 {Exif} 里）
        let exifLensModel = (exif?["LensModel"] as? String ?? props["LensModel"] as? String)
            .map(trimMetadataText)
        if let exifLensModel {
            lines.append(InfoItem(label: "镜头型号", value: exifLensModel))
        }
        // Adobe XMP 中单独记录的镜头描述。
        if let v = xmpLens.map(trimMetadataText), v != exifLensModel {
            lines.append(InfoItem(label: "镜头描述", value: v))
        }
        // 镜头ID（在 {ExifAux} 里，可能是 Int 或其他类型）
        if let v = exifAux?["LensID"] {
            if String(describing: v) != "65535" {
                lines.append(InfoItem(label: "镜头ID", value: String(describing: v)))
            }
        }
        // 镜头规格
        if let v = (props["LensSpecification"] as? [Any]) ?? (exif?["LensSpecification"] as? [Any]), !v.isEmpty {
            lines.append(InfoItem(label: "镜头规格", value: formatLensSpec(v)))
        }
        // 创建时间
        if let v = props["DateTime"] as? String { lines.append(InfoItem(label: "创建时间", value: v)) }
        // 拍摄时间
        if let v = exif?["DateTimeOriginal"] as? String { lines.append(InfoItem(label: "拍摄时间", value: v)) }
        // 曝光时间
        if let v = exif?["ExposureTime"] as? Double {
            if v > 0.0 {
                lines.append(InfoItem(label: "曝光时间", value: formatExposure(v)))
            }
        }
        // 光圈值
        if let v = exif?["FNumber"] as? Double {
            if v > 0.0 {
                lines.append(InfoItem(label: "光圈值", value: "f/\(trimNumber(v))"))
            }

        }
        // ISO
        if let arr = exif?["ISOSpeedRatings"] as? [Any],
           let iso = arr.first as? Int {
            if iso > 0 {
                lines.append(InfoItem(label: "ISO", value: "\(iso)"))
            }
        } else if let v = exif?["ISOSpeed"] as? Int {
            if v > 0 {
                lines.append(InfoItem(label: "ISO", value: "\(v)"))
            }
        }
        // 闪光灯：bit0=1 表示触发
        if let v = exif?["Flash"] as? Int {
            lines.append(InfoItem(label: "闪光灯", value: (v & 0x01) != 0 ? "触发" : "未触发"))
        }
        // 白平衡
        if let v = exif?["WhiteBalance"] as? Int {
            lines.append(InfoItem(label: "白平衡", value: v == 0 ? "自动" : "手动"))
        }
        // 焦距
        if let v = exif?["FocalLength"] as? Double {
            if v > 0.0 {
                lines.append(InfoItem(label: "焦距", value: "\(Int(v)) mm"))
            }

        }
        // 仅在与实际焦距不同时显示 35mm 等效焦距。
        if let focalLength = numberValue(exif?["FocalLength"]),
           let equivalentFocalLength = numberValue(exif?["FocalLenIn35mmFilm"]),
           focalLength > 0, equivalentFocalLength > 0,
           abs(equivalentFocalLength - focalLength) > 0.0001 {
            lines.append(InfoItem(
                label: "35mm等效焦距",
                value: "\(trimNumber(equivalentFocalLength)) mm"
            ))
        }
        // Sony 将对焦位置保存在 MakerNote 的加密 Tag9402 中。FocusDistance2 是
        // ExifTool 基于该位置与 35mm 等效焦距计算出的组合字段，不是标准 EXIF 标签。
        let lensModel = trimMetadataText(
            (exif?["LensModel"] as? String) ?? (props["LensModel"] as? String) ?? ""
        )
        let hidesFocusDistance = lensModel.lowercased().hasPrefix("viltrox")
            || lensModel.lowercased().hasPrefix("7artisans")
        let focalLength35mm = numberValue(exif?["FocalLenIn35mmFilm"])
            ?? numberValue(exif?["FocalLength"])
        let cameraMake = ((tiff?["Make"] as? String) ?? (props["Make"] as? String) ?? "").lowercased()
        let nikonMaker = props["{MakerNikon}"] as? [String: Any]
        let focusDistance: Double?
        if cameraMake.contains("nikon") {
            let serialNumber = numberValue(exif?["BodySerialNumber"])
                ?? numberValue(exifAux?["SerialNumber"])
            let shutterCount = numberValue(nikonMaker?["ShutterCount"])
            focusDistance = nikonFocusDistance(from: url, serialNumber: serialNumber, shutterCount: shutterCount)
        } else if let focalLength35mm {
            focusDistance = sonyFocusDistance2(from: url, focalLength35mm: focalLength35mm)
        } else {
            focusDistance = nil
        }
        if !hidesFocusDistance, let focusDistance {
            let value = focusDistance.isInfinite ? "∞" : String(format: "%.2f m", focusDistance)
            lines.append(InfoItem(label: "对焦距离", value: value))
        }
        // 纬度
        if let v = gps?["Latitude"] as? Double {
            let ref = gps?["LatitudeRef"] as? String ?? ""
            lines.append(InfoItem(label: "纬度", value: "\(v)\(ref)"))
        }
        // 经度
        if let v = gps?["Longitude"] as? Double {
            let ref = gps?["LongitudeRef"] as? String ?? ""
            lines.append(InfoItem(label: "经度", value: "\(v)\(ref)"))
        }
        return lines
    }

    // 镜头规格：[最短焦, 最长焦, 最大光圈(短焦), 最大光圈(长焦)]
    private func formatLensSpec(_ spec: [Any]) -> String {
        let nums = spec.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) }
        guard nums.count == 4 else {
            return spec.map { String(describing: $0) }.joined(separator: " / ")
        }
        // 定焦镜头（最短=最长）不显示变焦范围
        let focal = nums[0] == nums[1] ? "\(Int(nums[0]))mm" : "\(Int(nums[0]))-\(Int(nums[1]))mm"
        let aMin = String(format: "%.1f", nums[2])
        let aMax = String(format: "%.1f", nums[3])
        let aperture = nums[2] == nums[3] ? "f/\(aMin)" : "f/\(aMin)-\(aMax)"
        return "\(focal) \(aperture)"
    }

    private func formatExposure(_ t: Double) -> String {
        if t < 1 && t > 0 {
            return "1/\(Int((1.0 / t).rounded())) s"
        }
        return "\(trimNumber(t)) s"
    }

    private func trimNumber(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : "\(v)"
    }

    private func trimMetadataText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toggleFocusPoints() {
        showFocusPoints.toggle()
        refreshFocusPoints()
    }

    /// 对焦框开关属于当前窗口；图片切换时仅更新该图的点位数据。
    private func refreshFocusPoints() {
        focusPoints = showFocusPoints
            ? (currentURL.flatMap(focusPoints(from:)) ?? [])
            : []
    }

    private func toggleActualSize() {
        guard !actualSize else {
            zoomAnchor = nil
            actualSize = false
            return
        }
        zoomAnchor = currentURL.flatMap(focusPointAnchor(for:))
        actualSize = true
    }

    /// Sony 的 MakerNote Y 坐标以图片顶部为原点，NSView 以底部为原点。
    private func focusPointAnchor(for url: URL) -> ZoomAnchor? {
        guard let points = focusPoints(from: url), !points.isEmpty else { return nil }
        let averageX = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let averageY = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        return ZoomAnchor(
            imageFraction: CGPoint(x: averageX, y: 1 - averageY),
            viewFraction: CGPoint(x: 0.5, y: 0.5)
        )
    }

    /// 读取 Sony MakerNote Tag202a 中的已使用对焦点，返回图片内的归一化坐标。
    private func sonyFocusPoints(from url: URL) -> [CGPoint]? {
        guard let imageData = try? Data(contentsOf: url),
              let exifRange = imageData.range(of: Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])) else {
            return nil
        }
        let orientation = imageOrientation(from: url)
        let tiffStart = exifRange.upperBound
        let marker = Data([0x2a, 0x20, 0x07, 0x00]) // Sony Tag202a, UNDEFINED
        var searchStart = tiffStart
        while let entryRange = imageData.range(of: marker, options: [], in: searchStart..<imageData.endIndex) {
            let entry = entryRange.lowerBound
            guard let byteCount = littleEndianUInt32(in: imageData, at: entry + 4),
                  let relativeOffset = littleEndianUInt32(in: imageData, at: entry + 8),
                  byteCount >= 6 else { return nil }
            let dataStart = tiffStart + Int(relativeOffset)
            let dataEnd = dataStart + Int(byteCount)
            guard dataStart >= tiffStart, dataEnd <= imageData.count else {
                searchStart = entry + 1
                continue
            }
            let pointCount = imageData[dataStart + 1]
            guard let areaWidth = littleEndianUInt16(in: imageData, at: dataStart + 2),
                  let areaHeight = littleEndianUInt16(in: imageData, at: dataStart + 4),
                  areaWidth > 0, areaHeight > 0 else { return nil }

            let availableCount = min(Int(pointCount), (Int(byteCount) - 6) / 4)
            let points = (0..<availableCount).compactMap { index -> CGPoint? in
                let offset = dataStart + 6 + index * 4
                guard let x = littleEndianUInt16(in: imageData, at: offset),
                      let y = littleEndianUInt16(in: imageData, at: offset + 2),
                      x != UInt16.max, y != UInt16.max else { return nil }
                return CGPoint(x: CGFloat(x) / CGFloat(areaWidth), y: CGFloat(y) / CGFloat(areaHeight))
            }
            if !points.isEmpty { return orientFocusPoints(points, orientation: orientation) }
            break // 跟踪/眼部 AF 不会写入静态点列表，改用 FocusLocation。
        }
        return sonyFocusLocation(in: imageData, tiffStart: tiffStart)
            .map { orientFocusPoints($0, orientation: orientation) }
    }

    /// 读取目前支持的相机对焦点，坐标已转换为图片显示方向。
    private func focusPoints(from url: URL) -> [CGPoint]? {
        let make = cameraMake(from: url)
        if make.contains("panasonic") { return panasonicFocusPoints(from: url) }
        if make.contains("nikon") { return nikonFocusPoints(from: url) }
        if make.contains("canon") { return canonFocusPoints(from: url) }
        return fujifilmFocusPoints(from: url) ?? sonyFocusPoints(from: url)
    }

    private func cameraMake(from url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return ""
        }
        let tiff = properties["{TIFF}"] as? [String: Any]
        return ((tiff?["Make"] as? String) ?? (properties["Make"] as? String) ?? "").lowercased()
    }

    /// Panasonic 将主 AF 区中心以 0 到 1 的归一化坐标写入 MakerNote Tag 0x004d。
    private func panasonicFocusPoints(from url: URL) -> [CGPoint]? {
        guard let imageData = try? Data(contentsOf: url),
              let exifRange = imageData.range(of: Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])) else {
            return nil
        }
        let tiffStart = exifRange.upperBound
        let marker = Data([0x4d, 0x00, 0x05, 0x00, 0x02, 0x00, 0x00, 0x00])
        var searchStart = tiffStart
        while let range = imageData.range(of: marker, options: [], in: searchStart..<imageData.endIndex) {
            let entry = range.lowerBound
            guard let relativeOffset = littleEndianUInt32(in: imageData, at: entry + 8) else {
                searchStart = range.upperBound
                continue
            }
            let dataStart = tiffStart + Int(relativeOffset)
            guard dataStart >= tiffStart,
                  dataStart + 16 <= imageData.endIndex,
                  let xNumerator = littleEndianUInt32(in: imageData, at: dataStart),
                  let xDenominator = littleEndianUInt32(in: imageData, at: dataStart + 4),
                  let yNumerator = littleEndianUInt32(in: imageData, at: dataStart + 8),
                  let yDenominator = littleEndianUInt32(in: imageData, at: dataStart + 12),
                  xDenominator > 0, yDenominator > 0 else {
                searchStart = range.upperBound
                continue
            }
            let point = CGPoint(
                x: CGFloat(Double(xNumerator) / Double(xDenominator)),
                y: CGFloat(Double(yNumerator) / Double(yDenominator))
            )
            guard (0...1).contains(point.x), (0...1).contains(point.y) else {
                searchStart = range.upperBound
                continue
            }
            return orientFocusPoints([point], orientation: imageOrientation(from: url))
        }
        return nil
    }

    /// Canon EOS R 系列的 AFInfo2（MakerNote Tag 0x0026）保存了有效对焦点坐标与对焦状态位图。
    private func canonFocusPoints(from url: URL) -> [CGPoint]? {
        guard let imageData = try? Data(contentsOf: url),
              let exifRange = imageData.range(of: Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])) else {
            return nil
        }
        let tiffStart = exifRange.upperBound
        let marker = Data([0x26, 0x00, 0x03, 0x00]) // CanonAFInfo2, SHORT
        var searchStart = tiffStart
        while let range = imageData.range(of: marker, options: [], in: searchStart..<imageData.endIndex) {
            let entry = range.lowerBound
            guard let valueCount = littleEndianUInt32(in: imageData, at: entry + 4),
                  let relativeOffset = littleEndianUInt32(in: imageData, at: entry + 8),
                  valueCount >= 16 else {
                searchStart = range.upperBound
                continue
            }
            let dataStart = tiffStart + Int(relativeOffset)
            let dataEnd = dataStart + Int(valueCount) * 2
            guard dataStart >= tiffStart, dataEnd <= imageData.endIndex,
                  let pointCount = littleEndianUInt16(in: imageData, at: dataStart + 4),
                  let validPointCount = littleEndianUInt16(in: imageData, at: dataStart + 6),
                  let imageWidth = littleEndianUInt16(in: imageData, at: dataStart + 12),
                  let imageHeight = littleEndianUInt16(in: imageData, at: dataStart + 14),
                  pointCount > 0, pointCount <= 5000,
                  validPointCount > 0, imageWidth > 0, imageHeight > 0 else {
                searchStart = range.upperBound
                continue
            }

            let count = Int(pointCount)
            let pointLimit = min(Int(validPointCount), count)
            let widthsOffset = dataStart + 16
            let heightsOffset = widthsOffset + count * 2
            let xOffset = heightsOffset + count * 2
            let yOffset = xOffset + count * 2
            let focusBitsOffset = yOffset + count * 2
            let focusBitsSize = ((count + 15) / 16) * 2
            guard focusBitsOffset + focusBitsSize <= dataEnd else {
                searchStart = range.upperBound
                continue
            }

            let focusedPoints = (0..<pointLimit).compactMap { index -> CGPoint? in
                guard let width = littleEndianInt16(in: imageData, at: widthsOffset + index * 2),
                      let height = littleEndianInt16(in: imageData, at: heightsOffset + index * 2),
                      let x = littleEndianInt16(in: imageData, at: xOffset + index * 2),
                      let y = littleEndianInt16(in: imageData, at: yOffset + index * 2),
                      width > 0, height > 0,
                      let word = littleEndianUInt16(in: imageData, at: focusBitsOffset + (index / 16) * 2),
                      (word & (UInt16(1) << UInt16(index % 16))) != 0 else {
                    return nil
                }
                // Canon EOS 的 AF 坐标以画面中心为原点，Y 轴向上为正。
                return CGPoint(
                    x: 0.5 + CGFloat(x) / CGFloat(imageWidth),
                    y: 0.5 - CGFloat(y) / CGFloat(imageHeight)
                )
            }
            if !focusedPoints.isEmpty {
                return orientFocusPoints(focusedPoints, orientation: imageOrientation(from: url))
            }
            searchStart = range.upperBound
        }
        return nil
    }

    /// Fujifilm 将已使用的对焦点像素坐标保存在 MakerNote Tag 0x1023（FocusPixel）。
    private func fujifilmFocusPoints(from url: URL) -> [CGPoint]? {
        guard let imageData = try? Data(contentsOf: url),
              imageData.range(of: Data("FUJIFILM".utf8)) != nil,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let imageWidth = numberValue(properties["PixelWidth"]),
              let imageHeight = numberValue(properties["PixelHeight"]),
              imageWidth > 0, imageHeight > 0 else {
            return nil
        }
        let marker = Data([0x23, 0x10, 0x03, 0x00, 0x02, 0x00, 0x00, 0x00])
        guard let range = imageData.range(of: marker) else { return nil }
        let entry = range.lowerBound
        guard let pointX = littleEndianUInt16(in: imageData, at: entry + 8),
              let pointY = littleEndianUInt16(in: imageData, at: entry + 10),
              Double(pointX) < imageWidth, Double(pointY) < imageHeight else {
            return nil
        }
        let point = CGPoint(
            x: CGFloat(Double(pointX) / imageWidth),
            y: CGFloat(Double(pointY) / imageHeight)
        )
        return orientFocusPoints([point], orientation: imageOrientation(from: url))
    }

    /// Nikon Z（Expeed 6，AFInfo2 03xx）将 AF 区域中心保存为相对 AF 图像的像素坐标。
    private func nikonFocusPoints(from url: URL) -> [CGPoint]? {
        guard let imageData = try? Data(contentsOf: url),
              imageData.range(of: Data("Nikon\0".utf8)) != nil else { return nil }

        for version in [Data("0300".utf8), Data("0301".utf8)] {
            var searchStart = imageData.startIndex
            while let range = imageData.range(of: version, options: [], in: searchStart..<imageData.endIndex) {
                let dataStart = range.lowerBound
                let dataEnd = dataStart + 0x36
                guard dataEnd <= imageData.endIndex,
                      imageData[dataStart + 7] == 1,
                      let imageWidth = littleEndianUInt16(in: imageData, at: dataStart + 0x2a),
                      let imageHeight = littleEndianUInt16(in: imageData, at: dataStart + 0x2c),
                      let pointX = littleEndianUInt16(in: imageData, at: dataStart + 0x2e),
                      let pointY = littleEndianUInt16(in: imageData, at: dataStart + 0x30),
                      imageWidth > 0, imageHeight > 0,
                      pointX < imageWidth, pointY < imageHeight else {
                    searchStart = range.upperBound
                    continue
                }
                let point = CGPoint(
                    x: CGFloat(pointX) / CGFloat(imageWidth),
                    y: CGFloat(pointY) / CGFloat(imageHeight)
                )
                return orientFocusPoints([point], orientation: imageOrientation(from: url))
            }
        }
        return nil
    }

    private func imageOrientation(from url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return 1
        }
        return Int(numberValue(properties["Orientation"]) ?? 1)
    }

    /// Sony 的 AF 坐标基于原始像素方向，需转换到 AppKit 实际显示的 EXIF 方向。
    private func orientFocusPoints(_ points: [CGPoint], orientation: Int) -> [CGPoint] {
        points.map { point in
            switch orientation {
            case 2: return CGPoint(x: 1 - point.x, y: point.y)
            case 3: return CGPoint(x: 1 - point.x, y: 1 - point.y)
            case 4: return CGPoint(x: point.x, y: 1 - point.y)
            case 5: return CGPoint(x: point.y, y: point.x)
            case 6: return CGPoint(x: 1 - point.y, y: point.x)
            case 7: return CGPoint(x: 1 - point.y, y: 1 - point.x)
            case 8: return CGPoint(x: point.y, y: 1 - point.x)
            default: return point
            }
        }
    }

    /// AF Tracking / Eye AF 的回退位置：宽、高、对焦点 X、对焦点 Y。
    private func sonyFocusLocation(in imageData: Data, tiffStart: Int) -> [CGPoint]? {
        let marker = Data([0x27, 0x20, 0x03, 0x00]) // Sony FocusLocation, SHORT[4]
        guard let entryRange = imageData.range(of: marker, options: [], in: tiffStart..<imageData.endIndex) else {
            return nil
        }
        let entry = entryRange.lowerBound
        guard let relativeOffset = littleEndianUInt32(in: imageData, at: entry + 8) else { return nil }
        let dataStart = tiffStart + Int(relativeOffset)
        guard let imageWidth = littleEndianUInt16(in: imageData, at: dataStart),
              let imageHeight = littleEndianUInt16(in: imageData, at: dataStart + 2),
              let pointX = littleEndianUInt16(in: imageData, at: dataStart + 4),
              let pointY = littleEndianUInt16(in: imageData, at: dataStart + 6),
              imageWidth > 0, imageHeight > 0,
              pointX != UInt16.max, pointY != UInt16.max else { return nil }
        return [CGPoint(x: CGFloat(pointX) / CGFloat(imageWidth), y: CGFloat(pointY) / CGFloat(imageHeight))]
    }

    private func numberValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    /// Nikon Z 系列的 FocusDistance 位于加密的 LensData0801 中。
    private func nikonFocusDistance(from url: URL, serialNumber: Double?, shutterCount: Double?) -> Double? {
        guard let serialNumber, let shutterCount,
              let imageData = try? Data(contentsOf: url) else { return nil }

        let marker = Data("0801".utf8)
        let searchStart = imageData.startIndex
        while let range = imageData.range(of: marker, options: [], in: searchStart..<imageData.endIndex) {
            let dataStart = range.lowerBound
            let dataEnd = dataStart + 108
            guard dataEnd <= imageData.endIndex else { return nil }

            var lensData = Array(imageData[dataStart..<dataEnd])
            nikonDecrypt(&lensData, serialNumber: UInt32(serialNumber), shutterCount: UInt32(shutterCount))
            // LensData0801 的 0x58 在无限远时为 0。
            if lensData[0x58] == 0 { return .infinity }
            let rawDistance = UInt16(lensData[0x4e]) | UInt16(lensData[0x4f]) << 8
            let distanceValue = Double(rawDistance) / 256.0
            guard rawDistance > 0 else { return nil }
            return pow(2.0, (distanceValue - 80.0) / 12.0)
        }
        return nil
    }

    private func nikonDecrypt(_ bytes: inout [UInt8], serialNumber: UInt32, shutterCount: UInt32) {
        let xlat = nikonTranslationTable
        let serialKey = Int(serialNumber & 0xff)
        let countKey = Int((shutterCount & 0xff) ^ ((shutterCount >> 8) & 0xff)
            ^ ((shutterCount >> 16) & 0xff) ^ ((shutterCount >> 24) & 0xff))
        let ci = Int(xlat[serialKey])
        var cj = Int(xlat[256 + countKey])
        var ck = 0x60
        for index in 4..<bytes.count {
            cj = (cj + ci * ck) & 0xff
            ck = (ck + 1) & 0xff
            bytes[index] ^= UInt8(cj)
        }
    }

    private var nikonTranslationTable: [UInt8] {
        let hex = "c1bf6d0d59c5139d83616b4fc77f3d3d5359e3c7e92f95a7951fdf7f2b29c70ddf07ef71893d133d3b13fb0d89c1651fb30d6b29e3fbefa36b477f9535a7474fc7f1599535112961f13db32b0d4389c19d9d8965f1e9dfbf3d7f5397e5e995171d3d8bfbc7e367a707f171a753b52989e52ba71729e94fc5656d6bef0d89492fb34353651d49a3138959ef6bef651d0b5913e34f9db329432b071d95595947fbe5e961472f357f177fef7f959571d3a30b71a3ad0b3bb5fba3bf4f831dade92f7165a3e507353d0db5e9e5473b9def35a3bfb3df53d397534971073561712f432f11df1797fb953b7f6bd325bfadc7c5c5b58bef2fd3076b25499525496d71c7a7bcc9ad91df85e5d478d517467c294c4d03e925681186b3bdf76f6122a226342abe1e4614689d4418c240f47e5f1bad0b94b667b40be1ea959c66dce75d6c05dad5df7aeff6db1f824cc06847a1bdee3950564adddfa5f8c6daca90ca01429d8b0c7343750594de24b38034e52cdc9b3fca3345d0db5ff552c321dae222726b3ed05ba8878c065d0fdd091993d0b9fc8b0f8460331c9b45f1f0a3943a1277334d4478283c9efd655716946bfb59d0c82236dbd2639843a1048786f7a626bbd6594dbf6a2eaa2befe678b64ee02fdc7cbe5719327e2ad0b8ba29003c527da8493b2deb2549faa3aa39a7c5a7501136fbc6674af5a512657eb0dfaf4eb3617f2f"
        return stride(from: 0, to: hex.count, by: 2).compactMap {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)
        }
    }

    /// 读取 Sony MakerNote Tag 0x9402 中的 FocusPosition2（偏移 0x2d），并采用
    /// ExifTool 的 FocusDistance2 换算公式。仅适用于包含该 Sony 标签的 JPEG 文件。
    private func sonyFocusDistance2(from url: URL, focalLength35mm: Double) -> Double? {
        guard let imageData = try? Data(contentsOf: url),
              let exifRange = imageData.range(of: Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])) else {
            return nil
        }
        let tiffStart = exifRange.upperBound

        // 在 Sony MakerNote IFD 中定位 Tag9402：tag=0x9402, type=UNDEFINED。
        let marker = Data([0x02, 0x94, 0x07, 0x00])
        var searchStart = tiffStart
        while let entryRange = imageData.range(of: marker, options: [], in: searchStart..<imageData.endIndex) {
            let entry = entryRange.lowerBound
            guard let byteCount = littleEndianUInt32(in: imageData, at: entry + 4),
                  let relativeOffset = littleEndianUInt32(in: imageData, at: entry + 8),
                  byteCount >= 46 else { return nil }
            let dataStart = tiffStart + Int(relativeOffset)
            let dataEnd = dataStart + Int(byteCount)
            guard dataStart >= tiffStart, dataEnd <= imageData.count else {
                searchStart = entry + 1
                continue
            }

            let position = Int(sonyDecipherByte(imageData[dataStart + 45])) // Tag9402 的 FocusPosition2
            guard position > 0 else { return nil }
            if position >= 255 { return .infinity }
            return (pow(2.0, Double(position) / 16.0 - 5.0) + 1.0) * focalLength35mm / 1000.0
        }
        return nil
    }

    private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func littleEndianInt16(in data: Data, at offset: Int) -> Int16? {
        littleEndianUInt16(in: data, at: offset).map(Int16.init(bitPattern:))
    }

    /// Sony 0x9402 使用的字节替换密码。这里只需解密 FocusPosition2 所在的一个字节。
    private func sonyDecipherByte(_ byte: UInt8) -> UInt8 {
        let table: [UInt8] = [
            0,1,50,177,10,14,135,40,2,204,202,173,27,220,8,237,100,134,240,79,140,108,184,203,105,196,44,3,151,182,147,124,20,243,226,62,48,142,215,96,28,161,171,55,236,117,190,35,21,106,89,63,208,185,150,181,80,39,136,227,129,148,224,192,4,92,198,232,95,75,112,56,159,130,128,81,43,197,69,73,155,33,82,83,84,133,11,93,97,218,123,85,38,36,7,110,54,91,71,183,217,74,162,223,191,18,37,188,30,127,86,234,16,230,207,103,77,60,145,131,225,49,179,111,244,5,138,70,200,24,118,104,189,172,146,42,19,233,15,163,122,219,61,212,231,58,26,87,175,32,66,178,158,195,139,242,213,211,164,126,31,152,156,238,116,165,166,167,216,94,176,180,52,206,168,121,119,90,193,137,174,154,17,51,157,245,57,25,101,120,22,113,210,169,68,99,64,41,186,160,143,228,214,59,132,13,194,78,88,221,153,34,107,201,187,23,6,229,125,102,67,98,246,205,53,144,46,65,141,109,170,9,115,149,12,241,29,222,76,47,45,247,209,114,235,239,72,199,248,249,250,251,252,253,254,255
        ]
        return table[Int(byte)]
    }

    private var placeholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("将图片拖到此处")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    /// 通过文件系统资源标识比较，兼容 Unicode 等价但文本不同的文件路径。
    private func imageIndex(for url: URL) -> Int? {
        let standardizedURL = url.standardizedFileURL
        if let index = folderImages.firstIndex(where: { $0.standardizedFileURL == standardizedURL }) {
            return index
        }
        guard let identifier = fileResourceIdentifier(for: url) else { return nil }
        return folderImages.firstIndex { candidate in
            fileResourceIdentifier(for: candidate)?.isEqual(identifier) == true
        }
    }

    private func fileResourceIdentifier(for url: URL) -> NSObject? {
        guard let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]) else {
            return nil
        }
        return values.fileResourceIdentifier as? NSObject
    }

    private func loadImage(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else {
            print("[EasyViewer] 无法加载图片: \(url.path)")
            return
        }
        droppedImage = image
        currentURL = url
        refreshFocusPoints()
        loadFolder(for: url)
        isFocused = true
    }

    // 枚举同一文件夹下的所有图片，按文件名排序
    private func loadFolder(for url: URL) {
        let dir = url.deletingLastPathComponent()
        do {
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "heif", "hif"]
        folderImages = urls.filter { fileURL in
            supportedExtensions.contains(fileURL.pathExtension.lowercased())
        }.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        } catch {
            print("[EasyViewer] 读取目录失败: \(error.localizedDescription)")
            folderImages = [url]
        }
    }

    // 打印当前图片信息
    private func logStatus() {
        guard let current = currentURL else { return }
        print("[EasyViewer] 拖入图片: \(current.path)")
        if folderImages.isEmpty {
            print("[EasyViewer] 当前图片: \(current.lastPathComponent)")
        } else {
            let idx = (imageIndex(for: current).map { $0 + 1 }) ?? 0
            print("[EasyViewer] 当前图片: \(current.lastPathComponent) — 文件夹中第 \(idx) / \(folderImages.count) 张")
        }
    }

    // 切换到前/后一张图片（循环）
    private func navigate(delta: Int) {
        guard let current = currentURL,
              let idx = imageIndex(for: current),
              !folderImages.isEmpty else { return }
        let count = folderImages.count
        let next = ((idx + delta) % count + count) % count
        let url = folderImages[next]
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return }
        currentURL = url
        droppedImage = image
        if actualSize {
            zoomAnchor = focusPointAnchor(for: url)
        }
        refreshFocusPoints()
    }

    @discardableResult
    private func moveCurrentImageToTrash() -> Bool {
        guard let current = currentURL,
              let index = imageIndex(for: current) else { return false }
        let companionRAWs = matchingRawFiles(for: current)
        do {
            try FileManager.default.trashItem(at: current, resultingItemURL: nil)
        } catch {
            print("[EasyViewer] 无法移到废纸篓: \(error.localizedDescription)")
            return true
        }
        for rawURL in companionRAWs {
            do {
                try FileManager.default.trashItem(at: rawURL, resultingItemURL: nil)
            } catch {
                print("[EasyViewer] 无法将配对 RAW 移到废纸篓 (\(rawURL.lastPathComponent)): \(error.localizedDescription)")
            }
        }

        folderImages.remove(at: index)
        guard !folderImages.isEmpty else {
            currentURL = nil
            droppedImage = nil
            focusPoints = []
            return true
        }

        // 删除后优先显示原位置的下一张；删除最后一张时显示前一张。
        let nextIndex = min(index, folderImages.count - 1)
        let nextURL = folderImages[nextIndex]
        guard let data = try? Data(contentsOf: nextURL),
              let image = NSImage(data: data) else {
            currentURL = nextURL
            droppedImage = nil
            return true
        }
        currentURL = nextURL
        droppedImage = image
        if actualSize {
            zoomAnchor = focusPointAnchor(for: nextURL)
        }
        refreshFocusPoints()
        return true
    }

    private func matchingRawFiles(for imageURL: URL) -> [URL] {
        let rawExtensions: Set<String> = ["ARW", "NEF", "CR2", "CR3", "RAF", "RW2"]
        let baseName = imageURL.deletingPathExtension().lastPathComponent
        let directory = imageURL.deletingLastPathComponent()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { url in
            rawExtensions.contains(url.pathExtension.uppercased())
                && url.deletingPathExtension().lastPathComponent == baseName
        }
    }
}

private struct InfoItem: Hashable {
    let label: String
    let value: String
}

struct ZoomAnchor: Equatable {
    /// 点击像素在图片内的归一化坐标。
    let imageFraction: CGPoint
    /// 点击点在图片容器内的归一化坐标，用于保持它在窗口中的显示位置。
    let viewFraction: CGPoint
}

// NSScrollView 容器，支持鼠标中键拖拽平移
struct PanScrollView: NSViewRepresentable {
    let image: NSImage
    let width: CGFloat
    let height: CGFloat
    let anchor: ZoomAnchor?
    let focusPoints: [CGPoint]
    let onZoomOut: () -> Void

    func makeNSView(context: Context) -> PanScrollContainer {
        let scrollView = PanScrollContainer()
        scrollView.contentView = CenteredClipView()
        let imageView = ZoomableImageView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.onZoomOut = onZoomOut
        imageView.focusPoints = focusPoints
        scrollView.documentView = imageView
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.backgroundColor = .clear
        scrollView.usesPredominantAxisScrolling = false
        scrollView.configure(anchor: anchor, image: image)
        return scrollView
    }

    /// 图片小于可视区域时，仅在未铺满的方向上居中。
    final class CenteredClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var bounds = super.constrainBoundsRect(proposedBounds)
            guard let documentView else { return bounds }

            if documentView.frame.width < proposedBounds.width {
                bounds.origin.x = (documentView.frame.width - proposedBounds.width) / 2
            }
            if documentView.frame.height < proposedBounds.height {
                bounds.origin.y = (documentView.frame.height - proposedBounds.height) / 2
            }
            return bounds
        }
    }

    func updateNSView(_ nsView: PanScrollContainer, context: Context) {
        guard let imageView = nsView.documentView as? NSImageView else { return }
        imageView.image = image
        imageView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if let imageView = imageView as? ZoomableImageView {
            imageView.onZoomOut = onZoomOut
            imageView.focusPoints = focusPoints
        }
        nsView.configure(anchor: anchor, image: image)
    }

    final class ZoomableImageView: NSImageView {
        var onZoomOut: () -> Void = {}
        var focusPoints: [CGPoint] = [] {
            didSet { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            drawFocusPoints(focusPoints, in: bounds)
        }

        override func mouseUp(with event: NSEvent) {
            if event.buttonNumber == 0 {
                onZoomOut()
            } else {
                super.mouseUp(with: event)
            }
        }
    }

    final class PanScrollContainer: NSScrollView {
        private var lastPanPoint: NSPoint?
        var needsCentering = false
        private var pendingAnchor: ZoomAnchor?
        private var appliedAnchor: ZoomAnchor?
        private var appliedImage: NSImage?
        private var hasConfiguredAnchor = false

        func configure(anchor: ZoomAnchor?, image: NSImage) {
            guard !hasConfiguredAnchor || anchor != appliedAnchor || image !== appliedImage else { return }
            pendingAnchor = anchor
            appliedAnchor = anchor
            appliedImage = image
            hasConfiguredAnchor = true
            needsCentering = anchor == nil
            needsLayout = true
        }

        override func layout() {
            super.layout()
            if needsCentering {
                centerContent()
                needsCentering = false
            } else if let anchor = pendingAnchor {
                positionContent(at: anchor)
                pendingAnchor = nil
            }
            centerUndersizedAxes()
        }

        private func centerContent() {
            guard let docFrame = documentView?.frame else { return }
            let clipBounds = contentView.bounds
            contentView.scroll(to: NSPoint(
                x: (docFrame.width - clipBounds.width) / 2,
                y: (docFrame.height - clipBounds.height) / 2
            ))
        }

        private func centerUndersizedAxes() {
            guard let docFrame = documentView?.frame else { return }
            let clipBounds = contentView.bounds
            var origin = clipBounds.origin
            var needsAdjustment = false

            if docFrame.width < clipBounds.width {
                origin.x = (docFrame.width - clipBounds.width) / 2
                needsAdjustment = true
            }
            if docFrame.height < clipBounds.height {
                origin.y = (docFrame.height - clipBounds.height) / 2
                needsAdjustment = true
            }
            if needsAdjustment, origin != clipBounds.origin {
                contentView.scroll(to: origin)
            }
        }

        private func positionContent(at anchor: ZoomAnchor) {
            guard let docFrame = documentView?.frame else { return }
            let clipBounds = contentView.bounds
            let pointInDocument = NSPoint(
                x: docFrame.width * anchor.imageFraction.x,
                y: docFrame.height * anchor.imageFraction.y
            )
            let pointInClip = NSPoint(
                x: clipBounds.width * anchor.viewFraction.x,
                y: clipBounds.height * anchor.viewFraction.y
            )
            let maxX = max(0, docFrame.width - clipBounds.width)
            let maxY = max(0, docFrame.height - clipBounds.height)
            let origin = NSPoint(
                x: min(max(0, pointInDocument.x - pointInClip.x), maxX),
                y: min(max(0, pointInDocument.y - pointInClip.y), maxY)
            )
            contentView.scroll(to: origin)
        }

        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 {
                lastPanPoint = event.locationInWindow
                NSCursor.closedHand.push()
            } else {
                super.otherMouseDown(with: event)
            }
        }

        override func otherMouseDragged(with event: NSEvent) {
            guard event.buttonNumber == 2, let last = lastPanPoint else {
                super.otherMouseDragged(with: event)
                return
            }
            let current = event.locationInWindow
            let dx = current.x - last.x
            let dy = current.y - last.y
            let clip = contentView
            var origin = clip.bounds.origin
            origin.x -= dx
            origin.y -= dy
            // 限制在文档范围内
            if let docFrame = documentView?.frame {
                let maxX = max(0, docFrame.width - clip.bounds.width)
                let maxY = max(0, docFrame.height - clip.bounds.height)
                origin.x = min(max(0, origin.x), maxX)
                origin.y = min(max(0, origin.y), maxY)
            }
            clip.scroll(to: origin)
            lastPanPoint = current
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 {
                lastPanPoint = nil
                NSCursor.pop()
            } else {
                super.otherMouseUp(with: event)
            }
        }

    }
}

// Fit 模式图片视图
struct FitImageView: NSViewRepresentable {
    let image: NSImage
    let focusPoints: [CGPoint]
    let onZoomIn: (ZoomAnchor) -> Void

    func makeNSView(context: Context) -> FitImageViewContainer {
        let view = FitImageViewContainer()
        let imageView = VImageImageView()
        imageView.sourceImage = image
        imageView.imageAlignment = .alignCenter
        imageView.autoresizingMask = [.width, .height]
        view.addSubview(imageView)
        view.imageView = imageView
        view.onZoomIn = onZoomIn
        view.focusPoints = focusPoints
        return view
    }

    func updateNSView(_ nsView: FitImageViewContainer, context: Context) {
        (nsView.imageView as? VImageImageView)?.sourceImage = image
        nsView.onZoomIn = onZoomIn
        nsView.focusPoints = focusPoints
    }

    /// 同步使用 Accelerate/vImage 高质量缩放，避免 Core Image 的 GPU 回读开销。
    final class VImageImageView: NSImageView {
        private var cachedSource: NSImage?
        private var cachedPixelSize: NSSize = .zero
        private var isLiveResizing = false
        private var needsPreviewRebuild = false

        var sourceImage: NSImage? {
            didSet {
                if sourceImage !== oldValue {
                    cachedSource = nil
                    cachedPixelSize = .zero
                }
                schedulePreviewRebuild()
            }
        }

        override func layout() {
            super.layout()
            schedulePreviewRebuild()
        }

        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            isLiveResizing = true
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            isLiveResizing = false
            if needsPreviewRebuild {
                needsPreviewRebuild = false
                rebuildPreviewIfNeeded()
            }
        }

        private func schedulePreviewRebuild() {
            guard !isLiveResizing else {
                needsPreviewRebuild = true
                return
            }
            rebuildPreviewIfNeeded()
        }

        private func rebuildPreviewIfNeeded() {
            guard let sourceImage,
                  let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  bounds.width > 0, bounds.height > 0,
                  sourceImage.size.width > 0, sourceImage.size.height > 0 else { return }
            let fitScale = min(bounds.width / sourceImage.size.width, bounds.height / sourceImage.size.height)
            let displaySize = NSSize(width: sourceImage.size.width * fitScale, height: sourceImage.size.height * fitScale)
            let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            let targetPixelSize = NSSize(width: ceil(displaySize.width * backingScale), height: ceil(displaySize.height * backingScale))
            guard targetPixelSize != cachedPixelSize || sourceImage !== cachedSource else { return }
            cachedSource = sourceImage
            cachedPixelSize = targetPixelSize

            guard targetPixelSize.width < CGFloat(cgImage.width),
                  targetPixelSize.height < CGFloat(cgImage.height),
                  let preview = vImagePreview(from: cgImage, targetPixelSize: targetPixelSize) else {
                image = sourceImage
                imageScaling = .scaleProportionallyUpOrDown
                return
            }
            image = NSImage(cgImage: preview, size: displaySize)
            imageScaling = .scaleNone
        }

        private func vImagePreview(from cgImage: CGImage, targetPixelSize: NSSize) -> CGImage? {
            guard cgImage.bitsPerComponent == 8,
                  cgImage.bitsPerPixel == 32,
                  let sourceData = cgImage.dataProvider?.data,
                  let sourceBytes = CFDataGetBytePtr(sourceData) else { return nil }
            var source = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: sourceBytes),
                height: vImagePixelCount(cgImage.height),
                width: vImagePixelCount(cgImage.width),
                rowBytes: cgImage.bytesPerRow
            )
            var destination = vImage_Buffer()
            let targetWidth = vImagePixelCount(targetPixelSize.width)
            let targetHeight = vImagePixelCount(targetPixelSize.height)
            guard vImageBuffer_Init(&destination, targetHeight, targetWidth, 32, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                return nil
            }
            defer { free(destination.data) }
            guard vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError,
                  let destinationData = destination.data else { return nil }
            let data = Data(bytes: destinationData, count: destination.rowBytes * Int(targetHeight))
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(
                width: Int(targetWidth), height: Int(targetHeight),
                bitsPerComponent: cgImage.bitsPerComponent, bitsPerPixel: cgImage.bitsPerPixel,
                bytesPerRow: destination.rowBytes,
                space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: cgImage.bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: true, intent: cgImage.renderingIntent
            )
        }
    }

    final class FitImageViewContainer: NSView {
        var imageView: NSImageView?
        var onZoomIn: (ZoomAnchor) -> Void = { _ in }
        var focusPoints: [CGPoint] = [] {
            didSet { focusOverlay?.focusPoints = focusPoints }
        }
        private var focusOverlay: FocusPointOverlayView?

        override func mouseUp(with event: NSEvent) {
            guard event.buttonNumber == 0,
                  let imageView,
                  let image = imageView.image else {
                super.mouseUp(with: event)
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            let imageRect = displayedImageRect(for: image)
            guard imageRect.contains(point) else {
                super.mouseUp(with: event)
                return
            }
            let imageFraction = CGPoint(
                x: (point.x - imageRect.minX) / imageRect.width,
                y: (point.y - imageRect.minY) / imageRect.height
            )
            let viewFraction = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
            onZoomIn(ZoomAnchor(imageFraction: imageFraction, viewFraction: viewFraction))
        }

        private func displayedImageRect(for image: NSImage) -> NSRect {
            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
            let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
            return NSRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }

        override func layout() {
            super.layout()
            if focusOverlay == nil {
                let overlay = FocusPointOverlayView(frame: bounds)
                overlay.autoresizingMask = [.width, .height]
                overlay.imageProvider = { [weak self] in self?.imageView?.image }
                overlay.focusPoints = focusPoints
                addSubview(overlay)
                focusOverlay = overlay
            }
        }

    }
}

private final class FocusPointOverlayView: NSView {
    var imageProvider: () -> NSImage? = { nil }
    var focusPoints: [CGPoint] = [] { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = imageProvider() else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let imageRect = NSRect(
            x: (bounds.width - imageSize.width * scale) / 2,
            y: (bounds.height - imageSize.height * scale) / 2,
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        drawFocusPoints(focusPoints, in: imageRect)
    }
}

private func drawFocusPoints(_ points: [CGPoint], in imageRect: NSRect) {
    guard !points.isEmpty else { return }
    NSColor.systemGreen.setStroke()
    for point in points {
        let center = NSPoint(
            x: imageRect.minX + point.x * imageRect.width,
            y: imageRect.minY + (1 - point.y) * imageRect.height
        )
        let size: CGFloat = 18
        let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        path.lineWidth = 2
        path.stroke()
    }
}

// 使用 AppKit NSView 注册 .fileURL 拖拽类型，可靠获取 Finder 拖入的文件 URL
struct FileDropZone: NSViewRepresentable {
    @Binding var isTargeted: Bool
    var onDrop: (URL) -> Void

    final class Coordinator {
        var onEnter: () -> Void = {}
        var onExit: () -> Void = {}
        var onDrop: (URL) -> Void = { _ in }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DropView {
        let v = DropView()
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        let c = context.coordinator
        c.onEnter = { isTargeted = true }
        c.onExit = { isTargeted = false }
        c.onDrop = { url in onDrop(url) }
    }

    final class DropView: NSView {
        var coordinator: Coordinator?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL])
        }
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            registerForDraggedTypes([.fileURL])
        }

        private func firstImageURL(from board: NSPasteboard) -> URL? {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            guard let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else { return nil }
            return urls.first { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .image)
            }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard firstImageURL(from: sender.draggingPasteboard) != nil else { return [] }
            coordinator?.onEnter()
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            coordinator?.onExit()
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { coordinator?.onExit() }
            guard let url = firstImageURL(from: sender.draggingPasteboard) else { return false }
            coordinator?.onDrop(url)
            return true
        }
    }
}

/// 直接监听 AppKit 键盘事件，避免 ⌘⌫ 被系统菜单快捷键抢占。
struct CommandDeleteHandler: NSViewRepresentable {
    var onCommandDelete: () -> Bool

    final class Coordinator {
        var handler: () -> Bool = { false }
        var monitor: Any?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        coordinator.handler = onCommandDelete
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard event.keyCode == 51, // Backspace
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  coordinator?.handler() == true else {
                return event
            }
            return nil
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = onCommandDelete
    }
}

/// 右键切换图片信息面板。
struct InfoPanelMouseHandler: NSViewRepresentable {
    var onRightClick: () -> Void

    final class Coordinator {
        var handler: () -> Void = {}
        var monitor: Any?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        coordinator.handler = onRightClick
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp) { [weak coordinator] event in
            coordinator?.handler()
            return nil
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = onRightClick
    }
}

/// 仅使用传统鼠标滚轮翻图；触控板与 Magic Mouse 的精细滚动会原样交给系统处理。
struct MouseWheelNavigationHandler: NSViewRepresentable {
    var onWheel: (CGFloat) -> Void

    final class Coordinator {
        var handler: (CGFloat) -> Void = { _ in }
        var monitor: Any?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        coordinator.handler = onWheel
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator] event in
            guard !event.hasPreciseScrollingDeltas,
                  event.scrollingDeltaY != 0 else {
                return event
            }
            coordinator?.handler(event.scrollingDeltaY)
            return nil
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = onWheel
    }
}

#Preview {
    ContentView()
}
