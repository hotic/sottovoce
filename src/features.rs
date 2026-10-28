//! Acoustic features, computed on the CPU in f64 and converted to f32.
//!
//! - `whisper_log_mel`: the 128-bin log-mel used by Qwen3-ASR, replicating transformers' WhisperFeatureExtractor (numpy version)
//! - `kaldi_fbank`: the 80-bin Kaldi-style fbank used by SenseVoice, replicating mlx-audio's compute_fbank_kaldi

use std::f64::consts::PI;

use realfft::RealFftPlanner;

/// Whisper log-mel: returns (data in row-major [n_mels][frames] layout, frame count). Frames = samples / 160
pub fn whisper_log_mel(pcm: &[f32], n_mels: usize) -> (Vec<f32>, usize) {
    const N_FFT: usize = 400;
    const HOP: usize = 160;
    let bins = N_FFT / 2 + 1;
    let filters = slaney_mel_filters(bins, n_mels, 16000.0, 8000.0);

    // center=True: reflect-pad n_fft/2 on each side (excluding the edge sample, like numpy reflect)
    let half = N_FFT / 2;
    let n = pcm.len();
    let reflect = |i: isize| -> f64 {
        let mut i = i;
        let last = n as isize - 1;
        // Very short audio needs repeated reflection; callers guarantee at least 1 second, this is just a fallback
        while i < 0 || i > last {
            i = if i < 0 { -i } else { 2 * last - i };
        }
        pcm[i as usize] as f64
    };
    let padded: Vec<f64> = (0..n + 2 * half).map(|i| reflect(i as isize - half as isize)).collect();
    let frames = 1 + (padded.len() - N_FFT) / HOP;

    // Periodic Hann window
    let window: Vec<f64> = (0..N_FFT).map(|i| 0.5 - 0.5 * (2.0 * PI * i as f64 / N_FFT as f64).cos()).collect();
    let mut planner = RealFftPlanner::<f64>::new();
    let fft = planner.plan_fft_forward(N_FFT);
    let mut input = fft.make_input_vec();
    let mut spectrum = fft.make_output_vec();
    let mut power = vec![0f64; bins];

    // Drop the last frame (log_spec[:, :-1])
    let used = frames - 1;
    let mut mel = vec![0f32; n_mels * used];
    for t in 0..used {
        let start = t * HOP;
        for i in 0..N_FFT {
            input[i] = padded[start + i] * window[i];
        }
        fft.process(&mut input, &mut spectrum).expect("FFT length is fixed, cannot fail");
        // The numpy version stores FFT results as complex64, so real and imaginary parts are rounded to f32 first
        for (p, c) in power.iter_mut().zip(&spectrum) {
            let (re, im) = (c.re as f32 as f64, c.im as f32 as f64);
            *p = re * re + im * im;
        }
        for m in 0..n_mels {
            let row = &filters[m * bins..(m + 1) * bins];
            let e: f64 = row.iter().zip(&power).map(|(w, p)| w * p).sum();
            mel[m * used + t] = e.max(1e-10).log10() as f32;
        }
    }
    // The following clamping and scaling happen in f32, matching numpy
    let max = mel.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
    let out = mel.iter().map(|&v| (v.max(max - 8.0) + 4.0) / 4.0).collect();
    (out, used)
}

/// Triangular filter bank with Slaney scale and Slaney normalization, laid out [n_mels][bins] (transformers.audio_utils.mel_filter_bank)
fn slaney_mel_filters(bins: usize, n_mels: usize, sr: f64, fmax: f64) -> Vec<f64> {
    const MIN_LOG_HZ: f64 = 1000.0;
    const MIN_LOG_MEL: f64 = 15.0;
    let logstep = 27.0 / 6.4f64.ln();
    let hz_to_mel = |f: f64| if f >= MIN_LOG_HZ { MIN_LOG_MEL + (f / MIN_LOG_HZ).ln() * logstep } else { 3.0 * f / 200.0 };
    let mel_to_hz = |m: f64| if m >= MIN_LOG_MEL { MIN_LOG_HZ * ((m - MIN_LOG_MEL) / logstep).exp() } else { 200.0 * m / 3.0 };

    let (mel_min, mel_max) = (hz_to_mel(0.0), hz_to_mel(fmax));
    let freqs: Vec<f64> = (0..n_mels + 2)
        .map(|i| mel_to_hz(mel_min + (mel_max - mel_min) * i as f64 / (n_mels + 1) as f64))
        .collect();
    let nyquist = (sr as usize / 2) as f64;
    let mut filters = vec![0f64; n_mels * bins];
    for m in 0..n_mels {
        let enorm = 2.0 / (freqs[m + 2] - freqs[m]);
        for k in 0..bins {
            let f = nyquist * k as f64 / (bins - 1) as f64;
            let down = (f - freqs[m]) / (freqs[m + 1] - freqs[m]);
            let up = (freqs[m + 2] - f) / (freqs[m + 2] - freqs[m + 1]);
            filters[m * bins + k] = down.min(up).max(0.0) * enorm;
        }
    }
    filters
}

/// Kaldi-style log-mel fbank (snip_edges, DC removal, pre-emphasis 0.97, Hamming window, zero-padded to 512).
/// Returns `n_mels` values per frame; empty if the audio is shorter than one frame
pub fn kaldi_fbank(pcm: &[f32], n_mels: usize) -> Vec<Vec<f32>> {
    const WIN: usize = 400;
    const SHIFT: usize = 160;
    const NFFT: usize = 512;
    if pcm.len() < WIN {
        return Vec::new();
    }
    let frames = 1 + (pcm.len() - WIN) / SHIFT;
    let window: Vec<f64> = (0..WIN).map(|i| 0.54 - 0.46 * (2.0 * PI * i as f64 / (WIN - 1) as f64).cos()).collect();
    let banks = kaldi_mel_banks(n_mels, NFFT, 16000.0, 20.0, 8000.0);

    let mut planner = RealFftPlanner::<f64>::new();
    let fft = planner.plan_fft_forward(NFFT);
    let mut input = fft.make_input_vec();
    let mut spectrum = fft.make_output_vec();
    let mut frame = vec![0f64; WIN];
    let mut out = Vec::with_capacity(frames);
    for t in 0..frames {
        // SenseVoice expects input on the 16-bit integer scale
        for i in 0..WIN {
            frame[i] = pcm[t * SHIFT + i] as f64 * 32768.0;
        }
        let mean = frame.iter().sum::<f64>() / WIN as f64;
        // mlx-audio's pre-emphasis keeps the first sample unchanged, the rest become x[i] - 0.97 x[i-1]
        input.fill(0.0);
        input[0] = (frame[0] - mean) * window[0];
        for i in 1..WIN {
            input[i] = ((frame[i] - mean) - 0.97 * (frame[i - 1] - mean)) * window[i];
        }
        fft.process(&mut input, &mut spectrum).expect("FFT length is fixed, cannot fail");
        let power: Vec<f64> = spectrum.iter().map(|c| c.norm_sqr()).collect();
        let row = (0..n_mels)
            .map(|m| {
                let e: f64 = banks[m].iter().zip(&power).map(|(w, p)| w * p).sum();
                e.max(1e-8).ln() as f32
            })
            .collect();
        out.push(row);
    }
    out
}

/// Kaldi mel filters: mel = 1127 ln(1 + f/700); each filter spans bins 0..nfft/2 (the last bin has weight 0)
fn kaldi_mel_banks(n_mels: usize, nfft: usize, sr: f64, low: f64, high: f64) -> Vec<Vec<f64>> {
    let mel = |f: f64| 1127.0 * (1.0 + f / 700.0).ln();
    let width = sr / nfft as f64;
    let (lo, hi) = (mel(low), mel(high));
    let delta = (hi - lo) / (n_mels + 1) as f64;
    (0..n_mels)
        .map(|b| {
            let left = lo + b as f64 * delta;
            let center = lo + (b + 1) as f64 * delta;
            let right = lo + (b + 2) as f64 * delta;
            let mut row: Vec<f64> = (0..nfft / 2)
                .map(|k| {
                    let m = mel(width * k as f64);
                    let up = (m - left) / (center - left);
                    let down = (right - m) / (right - center);
                    up.min(down).max(0.0)
                })
                .collect();
            row.push(0.0);
            row
        })
        .collect()
}
