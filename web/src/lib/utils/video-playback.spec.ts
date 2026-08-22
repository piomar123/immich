import { resolveVideoPlaybackMode } from './video-playback';

describe('resolveVideoPlaybackMode', () => {
  it('plays the original file, bypassing HLS, when original playback is requested and real-time transcoding is enabled', () => {
    expect(resolveVideoPlaybackMode({ playOriginalVideo: true, realtimeTranscodingEnabled: true })).toEqual({
      urlSource: 'original',
      useHlsPlayer: false,
    });
  });

  it('plays the original file when original playback is requested and real-time transcoding is disabled', () => {
    expect(resolveVideoPlaybackMode({ playOriginalVideo: true, realtimeTranscodingEnabled: false })).toEqual({
      urlSource: 'original',
      useHlsPlayer: false,
    });
  });

  it('uses the real-time HLS stream when original playback is not requested and real-time transcoding is enabled', () => {
    expect(resolveVideoPlaybackMode({ playOriginalVideo: false, realtimeTranscodingEnabled: true })).toEqual({
      urlSource: 'hls',
      useHlsPlayer: true,
    });
  });

  it('falls back to the pre-transcoded playback file when neither original playback nor real-time transcoding apply', () => {
    expect(resolveVideoPlaybackMode({ playOriginalVideo: false, realtimeTranscodingEnabled: false })).toEqual({
      urlSource: 'transcoded',
      useHlsPlayer: false,
    });
  });
});
