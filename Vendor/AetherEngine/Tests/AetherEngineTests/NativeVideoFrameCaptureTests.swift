import AVFoundation
import Testing
@testable import AetherEngine

@MainActor
@Suite
struct NativeVideoFrameCaptureTests {
    private let tenBitVideoRange = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    private func hasVideoFrameOutput(_ item: AVPlayerItem) -> Bool {
        item.outputs.contains { $0 is AVPlayerItemVideoOutput }
    }

    private func makeTenBitVideoRangeBuffer(width: Int = 16, height: Int = 8,
                                            lumaCode: UInt16) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(tenBitVideoRange),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, tenBitVideoRange,
                                         attributes as CFDictionary, &pixelBuffer)
        try #require(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        try #require(CVPixelBufferGetPlaneCount(buffer) == 2)
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let yPlane = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let uvPlane = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let encodedLuma = lumaCode << 6
        let encodedChroma = UInt16(512 << 6)
        for row in 0..<height {
            let samples = yPlane.advanced(by: row * yStride).assumingMemoryBound(to: UInt16.self)
            for column in 0..<width { samples[column] = encodedLuma }
        }
        for row in 0..<(height / 2) {
            let samples = uvPlane.advanced(by: row * uvStride).assumingMemoryBound(to: UInt16.self)
            for column in 0..<width { samples[column] = encodedChroma }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return buffer
    }

    @Test("disabled frame capture stays disabled across an item swap")
    func disabledCaptureSurvivesSwap() throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        let url = URL(string: "http://127.0.0.1:1/capture-test.m3u8")!

        host.load(url: url, startPosition: nil, contract: .init(
            allowsVideoFrameCapture: false,
            videoFrameCapturePixelFormat: tenBitVideoRange))
        let firstItem = try #require(host.avPlayer.currentItem)
        #expect(!hasVideoFrameOutput(firstItem))

        host.swapItem(url: url, startPosition: nil)
        let swappedItem = try #require(host.avPlayer.currentItem)
        #expect(!hasVideoFrameOutput(swappedItem))
        #expect(!host.sessionContract.allowsVideoFrameCapture)
        #expect(host.sessionContract.videoFrameCapturePixelFormat == tenBitVideoRange)
        #expect(host.videoFrameCaptureDebugSummary == "VIDTAP enabled=no requested=x420 actual=pending")
    }

    @Test("a new session enables frame capture by default")
    func newSessionUsesDefaultCapturePolicy() throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        let url = URL(string: "http://127.0.0.1:1/capture-test.m3u8")!

        host.load(url: url, startPosition: nil, contract: .init(allowsVideoFrameCapture: false))
        host.load(url: url, startPosition: nil, contract: .init())

        let item = try #require(host.avPlayer.currentItem)
        #expect(host.sessionContract.allowsVideoFrameCapture)
        #expect(host.sessionContract.videoFrameCapturePixelFormat == kCVPixelFormatType_32BGRA)
        #expect(hasVideoFrameOutput(item))
        #expect(host.videoFrameCaptureDebugSummary == "VIDTAP enabled=yes requested=BGRA actual=pending")
    }

    @Test("x420 capture policy survives swaps and a new session resets to BGRA")
    func x420CapturePolicySurvivesSwapAndResets() throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        let url = URL(string: "http://127.0.0.1:1/capture-test.m3u8")!

        host.load(url: url, startPosition: nil,
                  contract: .init(videoFrameCapturePixelFormat: tenBitVideoRange))
        let firstItem = try #require(host.avPlayer.currentItem)
        #expect(hasVideoFrameOutput(firstItem))
        #expect(host.sessionContract.videoFrameCapturePixelFormat == tenBitVideoRange)

        host.swapItem(url: url, startPosition: nil)
        let swappedItem = try #require(host.avPlayer.currentItem)
        #expect(hasVideoFrameOutput(swappedItem))
        #expect(host.sessionContract.videoFrameCapturePixelFormat == tenBitVideoRange)

        host.load(url: url, startPosition: nil, contract: .init())
        let newSessionItem = try #require(host.avPlayer.currentItem)
        #expect(host.sessionContract.videoFrameCapturePixelFormat == kCVPixelFormatType_32BGRA)
        #expect(hasVideoFrameOutput(newSessionItem))
    }

    @Test("synthetic x420 video-range frames render as scaled 8-bit sRGB thumbnails")
    func tenBitFramesRenderAsSDRThumbnails() throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }

        for legalLumaCode in [UInt16(64), UInt16(512)] {
            let buffer = try makeTenBitVideoRangeBuffer(lumaCode: legalLumaCode)
            let thumbnail = try #require(host.renderThumbnail(from: buffer, maxWidth: 8))
            #expect(thumbnail.width == 8)
            #expect(thumbnail.height == 4)
            #expect(thumbnail.bitsPerComponent == 8)
            #expect(thumbnail.bitsPerPixel == 32)
            #expect(thumbnail.colorSpace?.name == CGColorSpace.sRGB)
        }
    }
}
