import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Proves the dec3 box (build.sh `patch_ffmpeg_eac3_dec3`) describes a track whose
/// height channels and Atmos objects live in a dependent substream.
///
/// The source class is a Blu-ray style Dolby Digital Plus track: an AC-3 core
/// syncframe (bsid 6, 640 kbps, 5.1) followed by an E-AC-3 dependent syncframe whose
/// chanmap adds Lvh/Rvh and whose addbsi carries the ETSI TS 103 420 JOC extension
/// (complexity_index_type_a 16). Stock movenc writes `14 00 0C 0F 02 00` for it:
/// chan_loc 0 and no extension, so tvOS decodes the 5.1 bed (AetherEngine #728).
///
/// Both headers are measured from a real file (AetherEngine PR #729), each zero-padded
/// to the frame length it declares. The muxer reads headers only, so the zeroed
/// payload does not matter; it is the same stream-copy path the HLS-fMP4 producer takes.
struct EAC3Dec3Tests {

    private static let ac3CoreHeader: [UInt8] = [
        0x0B, 0x77, 0x5B, 0x17, 0x24, 0x30, 0xE1, 0xFF, 0xFC, 0xE2, 0x69, 0xC0,
        0x00, 0x03, 0xE9, 0x55, 0xE1, 0x86, 0x18, 0x61, 0xFF, 0x3A, 0xBE, 0x7C,
    ]
    private static let eac3DependentHeader: [UInt8] = [
        0x0B, 0x77, 0x46, 0xFF, 0x3A, 0x87, 0xFF, 0xFA, 0x01, 0x02, 0x08, 0x08,
        0x80, 0x0D, 0x00, 0x00, 0x00, 0x14, 0x02, 0x00, 0xC3, 0x0C, 0x30, 0xFF,
    ]

    private static var corePlusDependent: [UInt8] {
        ac3CoreHeader + [UInt8](repeating: 0, count: 2560 - ac3CoreHeader.count)
            + eac3DependentHeader + [UInt8](repeating: 0, count: 3584 - eac3DependentHeader.count)
    }

    private static var coreOnly: [UInt8] {
        ac3CoreHeader + [UInt8](repeating: 0, count: 2560 - ac3CoreHeader.count)
    }

    /// Muxes `count` copies of `packet` as stream-copied E-AC-3 into an in-memory mp4
    /// and returns the dec3 payload. `engineFlags` uses the movflags of AetherEngine's
    /// MP4SegmentMuxer, where the moov goes out on the first flush; without them the
    /// moov is written by the trailer, after every packet has passed through the muxer.
    private static func dec3Payload(packet: [UInt8], count: Int, engineFlags: Bool) -> [UInt8]? {
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&ctxOut, nil, "mp4", "probe.mp4") == 0,
              let ctx = ctxOut else { return nil }
        defer { avformat_free_context(ctx) }

        var pb: UnsafeMutablePointer<AVIOContext>?
        guard avio_open_dyn_buf(&pb) >= 0, let sink = pb else { return nil }
        ctx.pointee.pb = sink

        guard let stream = avformat_new_stream(ctx, nil) else { return nil }
        let par = stream.pointee.codecpar!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_EAC3
        par.pointee.sample_rate = 48_000
        par.pointee.frame_size = 1536
        av_channel_layout_default(&par.pointee.ch_layout, 6)
        stream.pointee.time_base = AVRational(num: 1, den: 48_000)

        var opts: OpaquePointer?
        if engineFlags {
            av_dict_set(&opts, "movflags", "+empty_moov+default_base_moof+frag_custom+delay_moov+frag_discont", 0)
        }
        let header = avformat_write_header(ctx, &opts)
        av_dict_free(&opts)
        guard header >= 0 else { return nil }

        guard let pkt = av_packet_alloc() else { return nil }
        var pktRef: UnsafeMutablePointer<AVPacket>? = pkt
        defer { av_packet_free(&pktRef) }
        for i in 0..<count {
            guard av_new_packet(pkt, Int32(packet.count)) >= 0 else { return nil }
            packet.withUnsafeBytes { _ = memcpy(pkt.pointee.data, $0.baseAddress!, packet.count) }
            pkt.pointee.pts = Int64(i) * 1536
            pkt.pointee.dts = pkt.pointee.pts
            pkt.pointee.duration = 1536
            pkt.pointee.flags = AV_PKT_FLAG_KEY
            guard av_write_frame(ctx, pkt) >= 0 else { return nil }
            if engineFlags { _ = av_write_frame(ctx, nil) }
        }
        _ = av_write_trailer(ctx)

        var buf: UnsafeMutablePointer<UInt8>?
        let size = Int(avio_close_dyn_buf(sink, &buf))
        defer { av_free(buf) }
        guard let buf, size > 0 else { return nil }
        let bytes = [UInt8](UnsafeBufferPointer(start: buf, count: size))

        let tag: [UInt8] = Array("dec3".utf8)
        guard let at = (4..<(bytes.count - 4)).first(where: { Array(bytes[$0..<$0 + 4]) == tag }) else {
            return nil
        }
        let boxSize = bytes[at - 4..<at].reduce(0) { $0 << 8 | Int($1) }
        return Array(bytes[at + 4..<at - 4 + boxSize])
    }

    @Test("an AC-3 core with a JOC dependent substream gets Lvh/Rvh and the JOC extension",
          arguments: [true, false])
    func dependentSubstreamJOC(engineFlags: Bool) {
        // Stock n8.1.3 writes 14 00 0C 0F 02 00: chan_loc 0x000, no TS 103 420 bytes.
        // chan_loc 0x040 is Lvh/Rvh; 01 10 is flag_ec3_extension_type_a + 16 objects.
        let payload = Self.dec3Payload(packet: Self.corePlusDependent, count: 8, engineFlags: engineFlags)
        #expect(payload == [0x14, 0x00, 0x0C, 0x0F, 0x02, 0x40, 0x01, 0x10])
    }

    @Test("an AC-3 core alone keeps the short box, no dependent substream and no extension")
    func coreOnlyUnchanged() {
        let payload = Self.dec3Payload(packet: Self.coreOnly, count: 8, engineFlags: false)
        #expect(payload == [0x14, 0x00, 0x0C, 0x0F, 0x00])
    }
}
