import AVFoundation
import Foundation

/// 音频对象在后台创建后只由播放器 actor 调用；unchecked 仅用于这一次拥有权交接。
/// 对应旧 SVGAAudioLayer 和 SVGAPlayer.stepToFrame 的帧区间，不进入 Metal 合成。
final class AudioPlayback: @unchecked Sendable {
    /// 与源片段一一对应的音频播放器，后续访问仅在同一个 SVGAPlayer actor。
    private let tracks: [(SVGAAudioClip, AVAudioPlayer)]
    /// 源帧率，用于计算当前帧对应的音频偏移。
    private let frameRate: Double

    /// 内部构造完整音频集合，不暴露可变 AVAudioPlayer。
    private init(tracks: [(SVGAAudioClip, AVAudioPlayer)], frameRate: Double) {
        self.tracks = tracks
        self.frameRate = frameRate
    }

    /// 后台解码音频头并准备播放；任一附件错误向安装阶段报告，取消不安装部分集合。
    @concurrent static func prepare(_ movie: SVGAMovie) async throws -> AudioPlayback {
        var tracks: [(SVGAAudioClip, AVAudioPlayer)] = []
        for clip in movie.audioClips {
            try Task.checkCancellation()
            guard let data = movie.audioData[clip.key] else { throw SVGAError.resource("音频附件缺失：\(clip.key)") }
            let player = try AVAudioPlayer(data: data)
            guard player.prepareToPlay() else { throw SVGAError.resource("音频准备失败：\(clip.key)") }
            tracks.append((clip, player))
        }
        try Task.checkCancellation()
        return AudioPlayback(tracks: tracks, frameRate: movie.frameRate)
    }

    /// 按影片帧对齐；暂停、seek、循环跳回起点都会纠正音频，超过片段末帧立即停止。
    func synchronize(frame: Int, playing: Bool) {
        for (clip, player) in tracks {
            let active = playing && frame >= clip.startFrame && frame < clip.endFrame
            guard active else {
                if player.isPlaying { player.pause() }
                continue
            }
            let position = Double(clip.startTimeMilliseconds) / 1000 + Double(frame - clip.startFrame) / frameRate
            if !player.isPlaying || abs(player.currentTime - position) > 0.1 {
                player.currentTime = position
            }
            if !player.isPlaying { player.play() }
        }
    }

    /// 安装替换或页面退出时同步停止所有片段，播放器的异步 shutdown 再释放集合。
    func stop() {
        for (_, player) in tracks { player.stop() }
    }
}
