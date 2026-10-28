//! Audio decoding: any container / codec -> 16 kHz mono f32.

use std::io::Write;
use std::path::PathBuf;
use std::process::Command;

use anyhow::{anyhow, bail, Result};

pub const SAMPLE_RATE: usize = 16000;

/// Demuxers ffmpeg may pick for an upload: audio containers plus MP4 / Matroska / WebM for video files. Playlist and
/// script formats (HLS, concat) open the files and URLs named inside them, so an upload could make the server read
/// audio from its own disk or fetch URLs on the caller's behalf
const DEMUXERS: &str = "wav,w64,mp3,aac,flac,ogg,mov,matroska,caf,aiff,amr,amrnb,amrwb,au,asf,wv";

/// Decoding failed (corrupt or empty audio); the API maps this to 400
#[derive(Debug)]
pub struct DecodeError(pub String);

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DecodeError {}

/// WAV that is already 16 kHz mono 16-bit (what the dictation app uploads) is read directly, saving an ffmpeg
/// process (~26 ms). Other formats are written to a temp file first and handed to ffmpeg: CAF / MP4 may keep
/// their index at the end of the file, and piped input cannot seek back.
pub fn decode(data: &[u8], suffix: &str, ffmpeg: &PathBuf) -> Result<Vec<f32>, DecodeError> {
    if let Some(pcm) = fast_wav(data) {
        return check(pcm);
    }
    let run = || -> Result<Vec<f32>> {
        let mut f = tempfile::Builder::new()
            .suffix(if suffix.is_empty() { ".bin" } else { suffix })
            .tempfile()?;
        f.write_all(data)?;
        f.flush()?;
        let out = Command::new(ffmpeg)
            // Only the uploaded temp file itself may be opened, and only as one of the formats above
            .args(["-nostdin", "-loglevel", "error", "-protocol_whitelist", "file", "-format_whitelist", DEMUXERS, "-i"])
            .arg(f.path())
            .args(["-f", "f32le", "-ac", "1", "-ar", &SAMPLE_RATE.to_string(), "pipe:1"])
            .output()
            .map_err(|e| match e.kind() {
                // Only 16 kHz mono WAV skips ffmpeg; the dictation app sends that, other clients may not
                std::io::ErrorKind::NotFound => anyhow!(
                    "ffmpeg not found at {}; install it (brew install ffmpeg) to accept audio other than 16 kHz mono 16-bit WAV",
                    ffmpeg.display()
                ),
                _ => anyhow!("failed to run ffmpeg ({}): {e}", ffmpeg.display()),
            })?;
        if !out.status.success() {
            bail!("audio decoding failed: {}", String::from_utf8_lossy(&out.stderr).trim());
        }
        Ok(out.stdout.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect())
    };
    check(run().map_err(|e| DecodeError(e.to_string()))?)
}

fn check(pcm: Vec<f32>) -> Result<Vec<f32>, DecodeError> {
    if pcm.is_empty() {
        return Err(DecodeError("audio is empty".into()));
    }
    Ok(pcm)
}

/// Parse a 16 kHz mono PCM16 WAV; returns None on any other format so ffmpeg handles it
pub fn fast_wav(data: &[u8]) -> Option<Vec<f32>> {
    if data.len() < 12 || &data[..4] != b"RIFF" || &data[8..12] != b"WAVE" {
        return None;
    }
    let mut pos = 12;
    let mut fmt_ok = false;
    // Scan chunk by chunk: ffmpeg and other tools insert LIST etc. between fmt and data, so the header is not always 44 bytes
    while pos + 8 <= data.len() {
        let id = &data[pos..pos + 4];
        let size = u32::from_le_bytes(data[pos + 4..pos + 8].try_into().ok()?) as usize;
        let body = &data[pos + 8..data.len().min(pos + 8 + size)];
        match id {
            b"fmt " if body.len() >= 16 => {
                let format = u16::from_le_bytes([body[0], body[1]]);
                let channels = u16::from_le_bytes([body[2], body[3]]);
                let rate = u32::from_le_bytes(body[4..8].try_into().ok()?);
                let bits = u16::from_le_bytes([body[14], body[15]]);
                fmt_ok = format == 1 && channels == 1 && rate as usize == SAMPLE_RATE && bits == 16;
                if !fmt_ok {
                    return None;
                }
            }
            b"data" if fmt_ok => {
                return Some(body.chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0).collect());
            }
            _ => {}
        }
        pos += 8 + size + (size & 1);
    }
    None
}
