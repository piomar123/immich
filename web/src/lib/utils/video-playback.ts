export type VideoUrlSource = 'original' | 'hls' | 'transcoded';

export interface VideoPlaybackMode {
  /** Which endpoint `assetFileUrl` should be built from. */
  urlSource: VideoUrlSource;
  /** Whether the real-time HLS player (`<hls-video>`) should be used, as opposed to a plain `<video>`. */
  useHlsPlayer: boolean;
}

/**
 * Decides how a video should be played given the two independent toggles that affect it:
 * whether the viewer asked for the original file, and whether the server has real-time
 * transcoding enabled.
 *
 * "Play original video" must win over real-time transcoding: the real-time HLS pipeline has
 * no original/passthrough rendition to switch to, so honoring it means bypassing HLS entirely
 * and loading the original file directly, the same way it works when real-time transcoding is off.
 */
export const resolveVideoPlaybackMode = (options: {
  playOriginalVideo: boolean;
  realtimeTranscodingEnabled: boolean;
}): VideoPlaybackMode => {
  const { playOriginalVideo, realtimeTranscodingEnabled } = options;

  if (playOriginalVideo) {
    return { urlSource: 'original', useHlsPlayer: false };
  }

  if (realtimeTranscodingEnabled) {
    return { urlSource: 'hls', useHlsPlayer: true };
  }

  return { urlSource: 'transcoded', useHlsPlayer: false };
};
