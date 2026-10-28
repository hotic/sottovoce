//! Sottovoce: an always-on local speech recognition server. Qwen3-ASR for final transcripts, SenseVoice
//! for live previews, all running on MLX.

pub mod audio;
pub mod engine;
pub mod features;
pub mod hotwords;
pub mod nn;
pub mod qwen3_asr;
pub mod sensevoice;
pub mod server;
