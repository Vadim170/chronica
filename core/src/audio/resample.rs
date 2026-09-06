//! Convert arbitrary-rate interleaved i16 PCM to 16kHz mono i16.
//!
//! OWNER: module agent. Replace the stub with a real implementation.
//!
//! Contract:
//! - `to_mono_16k_i16(interleaved, in_sr, in_channels)` downmixes to mono
//!   (average channels) and resamples `in_sr` -> 16000.
//! - Output is i16 clamped to [-32768, 32767].
//! - Empty input or invalid metadata (`in_sr == 0` / `in_channels == 0`) ->
//!   empty output. `in_sr == 16000 && in_channels == 1` is a fast path (copy).
//! - Quality: a naive linear interpolation is the accepted baseline, but
//!   prefer cheap anti-aliasing (e.g. averaging decimation when downsampling
//!   by an integer factor) since the legacy `np.interp` aliased. Keep it
//!   allocation-light — this runs on every captured block.
//!
//! TARGET_SAMPLE_RATE = 16000.

pub const TARGET_SAMPLE_RATE: u32 = 16_000;

#[inline]
fn clamp_round_i16(v: f32) -> i16 {
    // Round half away from zero (matches numpy.round's behavior closely enough
    // for audio; rounding mode differences are inaudible) then clamp.
    let r = v.round();
    if r <= -32768.0 {
        -32768
    } else if r >= 32767.0 {
        32767
    } else {
        r as i16
    }
}

/// See module docs for the contract.
pub fn to_mono_16k_i16(interleaved: &[i16], in_sr: u32, in_channels: u8) -> Vec<i16> {
    // Empty input -> empty output.
    if interleaved.is_empty() {
        return Vec::new();
    }
    // Invalid capture metadata must be dropped at this boundary.  In
    // particular, allowing a zero sample rate through to the interpolation
    // path would divide by zero; zero channels must not silently become mono.
    if in_sr == 0 || in_channels == 0 {
        return Vec::new();
    }
    let channels = in_channels.max(1) as usize;

    // Fast path: already 16k mono -> straight copy.
    if in_sr == TARGET_SAMPLE_RATE && channels == 1 {
        return interleaved.to_vec();
    }

    // Number of complete frames available.
    let src_len = interleaved.len() / channels;
    if src_len == 0 {
        return Vec::new();
    }

    // Downmix to mono f32 (average across channels). For mono this is just a
    // cast, with no extra allocation beyond the single mono buffer.
    let mut mono: Vec<f32> = Vec::with_capacity(src_len);
    if channels == 1 {
        mono.extend(interleaved.iter().take(src_len).map(|&s| s as f32));
    } else {
        for frame in interleaved.chunks_exact(channels).take(src_len) {
            let sum: f32 = frame.iter().map(|&s| s as f32).sum();
            mono.push(sum / channels as f32);
        }
    }

    // No rate change -> just quantize the mono signal.
    if in_sr == TARGET_SAMPLE_RATE {
        return mono.into_iter().map(clamp_round_i16).collect();
    }

    // Integer-factor downsample -> averaging decimation (cheap anti-aliasing,
    // unlike the legacy np.interp which aliased).
    if in_sr > TARGET_SAMPLE_RATE && in_sr % TARGET_SAMPLE_RATE == 0 {
        let factor = (in_sr / TARGET_SAMPLE_RATE) as usize;
        let dst_len = src_len.div_ceil(factor); // ceil; keep all groups
        let mut out: Vec<i16> = Vec::with_capacity(dst_len);
        for group in mono.chunks(factor) {
            let sum: f32 = group.iter().sum();
            out.push(clamp_round_i16(sum / group.len() as f32));
        }
        return out;
    }

    // General case: linear interpolation. Sample positions mirror the legacy
    // np.linspace(0,1,n,endpoint=False) mapping so output length matches.
    let dst_len = ((src_len as u64 * TARGET_SAMPLE_RATE as u64 + (in_sr as u64) / 2) / in_sr as u64)
        .max(1) as usize;

    let mut out: Vec<i16> = Vec::with_capacity(dst_len);
    if src_len == 1 {
        // Single source sample: every output equals it.
        let v = clamp_round_i16(mono[0]);
        out.resize(dst_len, v);
        return out;
    }

    // x_old positions: i / src_len ; x_new positions: j / dst_len (endpoint=False).
    // The fractional source index for output j is j*src_len/dst_len.
    let step = src_len as f64 / dst_len as f64;
    for j in 0..dst_len {
        let pos = j as f64 * step; // fractional source index
        let idx = pos.floor() as usize;
        if idx >= src_len - 1 {
            // Clamp to last sample (np.interp holds the right edge).
            out.push(clamp_round_i16(mono[src_len - 1]));
        } else {
            let frac = (pos - idx as f64) as f32;
            let a = mono[idx];
            let b = mono[idx + 1];
            out.push(clamp_round_i16(a + (b - a) * frac));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_empty_output() {
        assert!(to_mono_16k_i16(&[], 48_000, 2).is_empty());
        assert!(to_mono_16k_i16(&[], 16_000, 1).is_empty());
    }

    #[test]
    fn invalid_metadata_is_dropped_without_panicking() {
        assert!(to_mono_16k_i16(&[1, 2], 0, 1).is_empty());
        assert!(to_mono_16k_i16(&[1, 2], 16_000, 0).is_empty());
    }

    #[test]
    fn mono_16k_is_copy() {
        let input = vec![0i16, 100, -200, 32767, -32768, 5];
        let out = to_mono_16k_i16(&input, 16_000, 1);
        assert_eq!(out, input);
    }

    #[test]
    fn stereo_downmix_to_mono() {
        // 16kHz stereo, no resample. Average of L/R per frame.
        // frames: (10,20)->15, (-100,100)->0, (32767,32767)->32767
        let input = vec![10i16, 20, -100, 100, 32767, 32767];
        let out = to_mono_16k_i16(&input, 16_000, 2);
        assert_eq!(out, vec![15, 0, 32767]);
    }

    #[test]
    fn stereo_downmix_length_halves() {
        let input = vec![0i16; 200]; // 100 stereo frames
        let out = to_mono_16k_i16(&input, 16_000, 2);
        assert_eq!(out.len(), 100);
    }

    #[test]
    fn downsample_48k_to_16k_length() {
        // 48000 -> 16000 is integer factor 3. 3000 samples mono -> ~1000 out.
        let n = 3000usize;
        let input: Vec<i16> = (0..n).map(|i| (i % 100) as i16).collect();
        let out = to_mono_16k_i16(&input, 48_000, 1);
        assert_eq!(out.len(), 1000);
    }

    #[test]
    fn downsample_48k_to_16k_averaging() {
        // factor 3 averaging: groups of 3.
        // [3,6,9, 0,0,0] -> [6, 0]
        let input = vec![3i16, 6, 9, 0, 0, 0];
        let out = to_mono_16k_i16(&input, 48_000, 1);
        assert_eq!(out, vec![6, 0]);
    }

    #[test]
    fn downsample_stereo_48k_to_16k() {
        // stereo, factor 3. 6 stereo frames -> 6 mono -> 2 out groups of 3.
        // frames mono: (2,4)->3, (6,8)->7, (10,12)->11, (0,0)->0, (0,0)->0, (0,0)->0
        // groups: [3,7,11]->7, [0,0,0]->0
        let input = vec![2i16, 4, 6, 8, 10, 12, 0, 0, 0, 0, 0, 0];
        let out = to_mono_16k_i16(&input, 48_000, 2);
        assert_eq!(out, vec![7, 0]);
    }

    #[test]
    fn upsample_8k_to_16k_length() {
        // 8000 -> 16000: non-integer-downsample path (upsample, linear).
        let n = 1000usize;
        let input: Vec<i16> = (0..n).map(|i| (i % 50) as i16).collect();
        let out = to_mono_16k_i16(&input, 8_000, 1);
        // Expect roughly double length.
        assert!(
            out.len() >= 1990 && out.len() <= 2010,
            "len = {}",
            out.len()
        );
    }

    #[test]
    fn non_integer_factor_44100_to_16k_length() {
        // 44100 -> 16000 is not an integer factor -> linear interp path.
        let n = 4410usize; // 0.1s at 44100
        let input: Vec<i16> = (0..n)
            .map(|i| ((i as f32 * 0.1).sin() * 1000.0) as i16)
            .collect();
        let out = to_mono_16k_i16(&input, 44_100, 1);
        // ~0.1s at 16000 = ~1600 samples.
        assert!(
            out.len() >= 1590 && out.len() <= 1610,
            "len = {}",
            out.len()
        );
    }

    #[test]
    fn sine_does_not_collapse_length() {
        // Generate a 440Hz sine at 48000, resample to 16000, check length & that
        // signal is non-trivial (not all zeros / not collapsed to one sample).
        let sr = 48_000u32;
        let secs = 0.25f32;
        let n = (sr as f32 * secs) as usize;
        let freq = 440.0f32;
        let input: Vec<i16> = (0..n)
            .map(|i| {
                let t = i as f32 / sr as f32;
                ((2.0 * std::f32::consts::PI * freq * t).sin() * 10_000.0) as i16
            })
            .collect();
        let out = to_mono_16k_i16(&input, sr, 1);
        assert_eq!(out.len(), n / 3);
        // Signal preserved: should have meaningful amplitude swing.
        let max = out.iter().copied().max().unwrap();
        let min = out.iter().copied().min().unwrap();
        assert!(max > 5000, "max amplitude too low: {}", max);
        assert!(min < -5000, "min amplitude too high: {}", min);
    }

    #[test]
    fn clamps_to_i16_range() {
        // Stereo frames that average to extreme values stay in range.
        let input = vec![32767i16, 32767, -32768, -32768];
        let out = to_mono_16k_i16(&input, 16_000, 2);
        assert_eq!(out, vec![32767, -32768]);
    }

    #[test]
    fn single_sample_no_panic() {
        let out = to_mono_16k_i16(&[12345i16], 44_100, 1);
        assert!(!out.is_empty());
        assert!(out.iter().all(|&v| v == 12345));
    }
}
