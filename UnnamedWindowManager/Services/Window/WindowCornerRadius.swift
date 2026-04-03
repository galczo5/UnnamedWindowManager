import AppKit

// Detects per-window corner radii using the SkyLight iterator API (same technique as JankyBorders).
// Falls back to pixel-scanning the window image, then to an OS-version heuristic.
// Results are cached per CGWindowID since a window's corner radius does not change during its lifetime.

private var radiusCache: [CGWindowID: CGFloat] = [:]

func windowCornerRadius(for windowID: CGWindowID) -> CGFloat {
    if let cached = radiusCache[windowID] { return cached }
    let radius = skyLightCornerRadius(for: windowID)
                 ?? pixelScanCornerRadius(for: windowID)
                 ?? defaultCornerRadius()
    radiusCache[windowID] = radius
    return radius
}

// MARK: - SkyLight iterator (preferred, matches JankyBorders)

// SkyLight private API function pointers, loaded once via dlsym.
private let skyLight: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    RTLD_LAZY | RTLD_LOCAL
)

private typealias SLSMainConnectionIDFunc       = @convention(c) () -> Int32
private typealias SLSWindowQueryWindowsFunc      = @convention(c) (Int32, CFArray, UInt32) -> CFTypeRef?
private typealias SLSWindowQueryResultCopyFunc   = @convention(c) (CFTypeRef) -> CFTypeRef?
private typealias SLSWindowIteratorAdvanceFunc   = @convention(c) (CFTypeRef) -> Bool
private typealias SLSWindowIteratorGetCountFunc  = @convention(c) (CFTypeRef) -> Int32
private typealias SLSWindowIteratorGetRadiiFunc  = @convention(c) (CFTypeRef) -> CFArray?

private let slsMainConnectionID: SLSMainConnectionIDFunc? = {
    guard let lib = skyLight, let sym = dlsym(lib, "SLSMainConnectionID") else { return nil }
    return unsafeBitCast(sym, to: SLSMainConnectionIDFunc.self)
}()

private let slsWindowQueryWindows: SLSWindowQueryWindowsFunc? = {
    guard let lib = skyLight, let sym = dlsym(lib, "SLSWindowQueryWindows") else { return nil }
    return unsafeBitCast(sym, to: SLSWindowQueryWindowsFunc.self)
}()

private let slsWindowQueryResultCopyWindows: SLSWindowQueryResultCopyFunc? = {
    guard let lib = skyLight, let sym = dlsym(lib, "SLSWindowQueryResultCopyWindows") else { return nil }
    return unsafeBitCast(sym, to: SLSWindowQueryResultCopyFunc.self)
}()

private let slsWindowIteratorAdvance: SLSWindowIteratorAdvanceFunc? = {
    guard let lib = skyLight, let sym = dlsym(lib, "SLSWindowIteratorAdvance") else { return nil }
    return unsafeBitCast(sym, to: SLSWindowIteratorAdvanceFunc.self)
}()

private let slsWindowIteratorGetCount: SLSWindowIteratorGetCountFunc? = {
    guard let lib = skyLight, let sym = dlsym(lib, "SLSWindowIteratorGetCount") else { return nil }
    return unsafeBitCast(sym, to: SLSWindowIteratorGetCountFunc.self)
}()

// Only available on macOS 26+.
private let slsWindowIteratorGetCornerRadii: SLSWindowIteratorGetRadiiFunc? = {
    guard let lib = skyLight, let sym = dlsym(lib, "SLSWindowIteratorGetCornerRadii") else { return nil }
    return unsafeBitCast(sym, to: SLSWindowIteratorGetRadiiFunc.self)
}()

private func skyLightCornerRadius(for windowID: CGWindowID) -> CGFloat? {
    guard let mainCID = slsMainConnectionID,
          let queryWindows = slsWindowQueryWindows,
          let resultCopy = slsWindowQueryResultCopyWindows,
          let iterAdvance = slsWindowIteratorAdvance,
          let iterGetCount = slsWindowIteratorGetCount,
          let iterGetRadii = slsWindowIteratorGetCornerRadii
    else { return nil }

    let cid = mainCID()
    let widNumber = NSNumber(value: windowID)
    let widArray = [widNumber] as CFArray
    guard let query = queryWindows(cid, widArray, 0x0) else { return nil }
    guard let iterator = resultCopy(query) else { return nil }

    guard iterGetCount(iterator) > 0, iterAdvance(iterator) else { return nil }

    guard let radiiArray = iterGetRadii(iterator) else { return nil }
    let arr = radiiArray as NSArray
    guard arr.count > 0, let num = arr[0] as? NSNumber else { return nil }

    let radius = CGFloat(num.floatValue)
    return radius > 0 ? radius : nil
}

// MARK: - Pixel-scan fallback

// CGWindowListCreateImage is unavailable in the macOS 26 SDK, so load it at runtime via dlsym.
private typealias CGWindowListCreateImageFunc = @convention(c) (
    CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption
) -> CGImage?

private let cgWindowListCreateImage: CGWindowListCreateImageFunc? = {
    guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: CGWindowListCreateImageFunc.self)
}()

/// Captures the window at 1x resolution, then scans the top row from the left edge inward.
/// The first pixel with alpha > 128 marks the corner radius in points.
private func pixelScanCornerRadius(for windowID: CGWindowID) -> CGFloat? {
    guard let createImage = cgWindowListCreateImage else { return nil }
    guard let image = createImage(
        .null,
        .optionIncludingWindow,
        windowID,
        [.boundsIgnoreFraming, .nominalResolution]
    ) else { return nil }

    guard image.width > 20, image.height > 20,
          let dataProvider = image.dataProvider,
          let data = dataProvider.data
    else { return nil }

    let ptr = CFDataGetBytePtr(data)!
    let bpp = image.bitsPerPixel / 8
    guard bpp >= 4 else { return nil }

    let alphaOffset: Int
    switch image.alphaInfo {
    case .premultipliedFirst, .first:
        alphaOffset = 0
    case .premultipliedLast, .last:
        alphaOffset = bpp - 1
    default:
        return nil
    }

    let maxScan = min(image.width, 100)
    for x in 0..<maxScan {
        if ptr[x * bpp + alphaOffset] > 128 {
            return CGFloat(x)
        }
    }
    return nil
}

// MARK: - OS-version fallback

private func defaultCornerRadius() -> CGFloat {
    if #available(macOS 26.0, *) { return 12 }
    return 9
}
