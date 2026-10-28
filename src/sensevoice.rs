//! SenseVoice-Small: SANM encoder + greedy CTC decoding, a few tens of ms per call, used for live dictation previews.
//!
//! A port of mlx-audio 0.5.9's `stt/models/sensevoice`. The vocabulary is parsed straight from the sentencepiece
//! model file and used only for decoding.

use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};
use mlx_rs::ops::indexing::IndexOp;
use mlx_rs::{nn as mnn, ops, transforms, Array};
use serde::Deserialize;

use crate::features::kaldi_fbank;
use crate::nn::{Embedding, Linear, Weights};

#[derive(Deserialize)]
struct Config {
    input_size: i32,
    encoder_conf: EncoderConf,
    frontend_conf: FrontendConf,
}

#[derive(Deserialize)]
struct EncoderConf {
    output_size: i32,
    attention_heads: i32,
    num_blocks: usize,
    tp_blocks: usize,
    kernel_size: i32,
    #[serde(default, alias = "sanm_shfit")]
    sanm_shift: i32,
}

#[derive(Deserialize)]
struct FrontendConf {
    n_mels: usize,
    lfr_m: usize,
    lfr_n: usize,
}

struct Layer {
    norm1: (Array, Array),
    qkv: Linear,
    out: Linear,
    fsmn: Array,
    norm2: (Array, Array),
    w1: Linear,
    w2: Linear,
    residual: bool,
}

pub struct SenseVoice {
    embed: Embedding,
    layers: Vec<Layer>,
    after_norm: (Array, Array),
    tp_layers: Vec<Layer>,
    tp_norm: (Array, Array),
    ctc: Linear,
    cmvn: (Vec<f32>, Vec<f32>),
    pieces: Vec<Piece>,
    heads: i32,
    d: i32,
    input_size: i32,
    pad: (i32, i32),
    n_mels: usize,
    lfr: (usize, usize),
}

impl SenseVoice {
    pub fn load(dir: &Path) -> Result<Self> {
        let cfg: Config = serde_json::from_slice(&std::fs::read(dir.join("config.json"))?)
            .context("failed to parse SenseVoice config.json")?;
        let enc = &cfg.encoder_conf;
        let mut w = Weights::load(dir, None)?;
        let norm = |w: &mut Weights, p: &str| -> Result<(Array, Array)> {
            Ok((w.take(&format!("{p}.weight"))?, w.take(&format!("{p}.bias"))?))
        };
        let layer = |w: &mut Weights, p: String, residual: bool| -> Result<Layer> {
            // Convert the FSMN conv kernel from PyTorch layout [C, 1, K] to MLX layout [C, K, 1]
            let fsmn = w.take(&format!("{p}.self_attn.fsmn_block.weight"))?.transpose_axes(&[0, 2, 1])?;
            Ok(Layer {
                norm1: norm(w, &format!("{p}.norm1"))?,
                qkv: w.linear(&format!("{p}.self_attn.linear_q_k_v"))?,
                out: w.linear(&format!("{p}.self_attn.linear_out"))?,
                fsmn,
                norm2: norm(w, &format!("{p}.norm2"))?,
                w1: w.linear(&format!("{p}.feed_forward.w_1"))?,
                w2: w.linear(&format!("{p}.feed_forward.w_2"))?,
                residual,
            })
        };
        // The first layer maps 560 -> 512 dims and has no residual
        let mut layers = vec![layer(&mut w, "encoder.encoders0.0".into(), cfg.input_size == enc.output_size)?];
        for i in 0..enc.num_blocks - 1 {
            layers.push(layer(&mut w, format!("encoder.encoders.{i}"), true)?);
        }
        let tp_layers = (0..enc.tp_blocks)
            .map(|i| layer(&mut w, format!("encoder.tp_encoders.{i}"), true))
            .collect::<Result<_>>()?;
        let left = (enc.kernel_size - 1) / 2 + enc.sanm_shift.max(0);
        let model = Self {
            embed: w.embedding("embed")?,
            layers,
            after_norm: norm(&mut w, "encoder.after_norm")?,
            tp_layers,
            tp_norm: norm(&mut w, "encoder.tp_norm")?,
            ctc: w.linear("ctc.ctc_lo")?,
            cmvn: parse_am_mvn(&std::fs::read_to_string(dir.join("am.mvn"))?)?,
            pieces: load_pieces(&dir.join("chn_jpn_yue_eng_ko_spectok.bpe.model"))?,
            heads: enc.attention_heads,
            d: enc.output_size,
            input_size: cfg.input_size,
            pad: (left, enc.kernel_size - 1 - left),
            n_mels: cfg.frontend_conf.n_mels,
            lfr: (cfg.frontend_conf.lfr_m, cfg.frontend_conf.lfr_n),
        };
        let left = w.leftover();
        if !left.is_empty() {
            bail!("SenseVoice: {} weights were not used, e.g. {}", left.len(), left[0]);
        }
        Ok(model)
    }

    /// `language`: auto / zh / en / yue / ja / ko; output gets inverse text normalization (digits, punctuation)
    pub fn transcribe(&self, pcm: &[f32], language: &str) -> Result<String> {
        let feats = self.features(pcm);
        if feats.is_empty() {
            return Ok(String::new());
        }
        let t = (feats.len() / self.input_size as usize) as i32;
        let feats = Array::from_slice(&feats, &[1, t, self.input_size]);

        // Prefix queries: language, event / emotion (1, 2), text normalization (14 = ITN on)
        let lid = match language {
            "zh" => 3,
            "en" => 4,
            "yue" => 7,
            "ja" => 11,
            "ko" => 12,
            _ => 0,
        };
        let q = |ids: &[i32]| self.embed.forward(&Array::from_slice(ids, &[1, ids.len() as i32]));
        let speech = ops::concatenate(&[q(&[lid])?, q(&[1, 2])?, q(&[14])?, feats], 1)?;

        let logits = self.ctc.forward(&self.encode(speech)?)?;
        let logp = mnn::log_softmax(&logits, -1)?;
        let pred = ops::indexing::argmax_axis(logp.index((0, 4.., ..)), -1, None)?;
        transforms::eval([&pred])?;

        // CTC: collapse consecutive repeats and drop blanks (0)
        let mut ids = Vec::new();
        let mut prev = None;
        for &t in pred.as_slice::<u32>() {
            if Some(t) != prev && t != 0 {
                ids.push(t);
            }
            prev = Some(t);
        }
        Ok(self.decode(&ids))
    }

    /// fbank -> LFR (stack 7 frames, stride 6) -> CMVN; returns row-major [T, 560]
    pub fn features(&self, pcm: &[f32]) -> Vec<f32> {
        let fbank = kaldi_fbank(pcm, self.n_mels);
        if fbank.is_empty() {
            return Vec::new();
        }
        let (m, n) = self.lfr;
        let left = (m - 1) / 2;
        let padded: Vec<&Vec<f32>> = std::iter::repeat_n(&fbank[0], left).chain(fbank.iter()).collect();
        let rows = fbank.len().div_ceil(n);
        let (means, istd) = &self.cmvn;
        let mut out = Vec::with_capacity(rows * m * self.n_mels);
        for i in 0..rows {
            for j in 0..m {
                // Pad past the end with the last frame
                let frame = padded.get(i * n + j).copied().unwrap_or(padded[padded.len() - 1]);
                out.extend_from_slice(frame);
            }
        }
        for (k, v) in out.iter_mut().enumerate() {
            let c = k % means.len();
            *v = (*v + means[c]) * istd[c];
        }
        out
    }

    fn encode(&self, x: Array) -> Result<Array> {
        let mut x = x.multiply(Array::from_f32((self.d as f32).sqrt()))?;
        x = x.add(position_encoding(x.dim(1), x.dim(2))?)?;
        for l in &self.layers {
            x = self.layer(l, &x)?;
        }
        x = mlx_rs::fast::layer_norm(&x, &self.after_norm.0, &self.after_norm.1, 1e-5)?;
        for l in &self.tp_layers {
            x = self.layer(l, &x)?;
        }
        Ok(mlx_rs::fast::layer_norm(&x, &self.tp_norm.0, &self.tp_norm.1, 1e-5)?)
    }

    fn layer(&self, l: &Layer, x: &Array) -> Result<Array> {
        let (b, t) = (x.dim(0), x.dim(1));
        let h = mlx_rs::fast::layer_norm(x, &l.norm1.0, &l.norm1.1, 1e-5)?;
        let qkv = l.qkv.forward(&h)?.split_equal(3, -1)?;
        let (q, k, v) = (&qkv[0], &qkv[1], &qkv[2]);

        // FSMN memory block: depthwise convolution over v, added back to v
        let padded = ops::pad(v, &[(0, 0), self.pad, (0, 0)][..], None, None)?;
        let fsmn = ops::conv1d(&padded, &l.fsmn, 1, 0, 1, self.d)?.add(v)?;

        let dk = self.d / self.heads;
        let split = |a: &Array| a.reshape(&[b, t, self.heads, dk])?.transpose_axes(&[0, 2, 1, 3]);
        let scores = split(q)?
            .multiply(Array::from_f32((dk as f32).powf(-0.5)))?
            .matmul(split(k)?.transpose_axes(&[0, 1, 3, 2])?)?;
        let attn = ops::softmax_axis(&scores, -1, None)?.matmul(split(v)?)?;
        let attn = attn.transpose_axes(&[0, 2, 1, 3])?.reshape(&[b, t, self.d])?;
        let attn = l.out.forward(&attn)?.add(&fsmn)?;

        let x = if l.residual { x.add(&attn)? } else { attn };
        let h = mlx_rs::fast::layer_norm(&x, &l.norm2.0, &l.norm2.1, 1e-5)?;
        Ok(x.add(l.w2.forward(&mnn::relu(l.w1.forward(&h)?)?)?)?)
    }

    fn decode(&self, ids: &[u32]) -> String {
        let mut bytes = Vec::new();
        for &id in ids {
            match self.pieces.get(id as usize) {
                Some(Piece { kind: PieceKind::Byte(b), .. }) => bytes.push(*b),
                Some(Piece { kind: PieceKind::Normal, text }) => bytes.extend_from_slice(text.as_bytes()),
                Some(Piece { kind: PieceKind::Unknown, .. }) => bytes.extend_from_slice(" ⁇ ".as_bytes()),
                _ => {}
            }
        }
        let text = String::from_utf8_lossy(&bytes).replace('▁', " ");
        text.trim().to_string()
    }
}

/// Position encoding: positions start at 1, sin in the first half, cos in the second
fn position_encoding(t: i32, dim: i32) -> Result<Array> {
    let half = dim / 2;
    let inc = (10000f64.ln() / (half - 1) as f64) as f32;
    let inv = ops::arange::<_, f32>(None, half, None)?.multiply(Array::from_f32(-inc))?.exp()?;
    let pos = ops::arange::<_, f32>(1, t + 1, None)?.reshape(&[1, t, 1])?;
    let s = pos.multiply(inv.reshape(&[1, 1, half])?)?;
    Ok(ops::concatenate(&[s.sin()?, s.cos()?], 2)?)
}

/// AddShift (negated mean) and Rescale (inverse std) from am.mvn
fn parse_am_mvn(text: &str) -> Result<(Vec<f32>, Vec<f32>)> {
    let section = |tag: &str| -> Result<Vec<f32>> {
        let rest = &text[text.find(tag).ok_or_else(|| anyhow!("am.mvn is missing {tag}"))?..];
        let rest = &rest[rest.find("<LearnRateCoef>").ok_or_else(|| anyhow!("am.mvn has an unexpected format"))?..];
        let (s, e) = (rest.find('[').unwrap_or(0) + 1, rest.find(']').unwrap_or(0));
        rest[s..e].split_whitespace().map(|x| x.parse::<f32>().map_err(Into::into)).collect()
    };
    Ok((section("<AddShift>")?, section("<Rescale>")?))
}

enum PieceKind {
    Normal,
    Unknown,
    Control,
    Byte(u8),
}

struct Piece {
    text: String,
    kind: PieceKind,
}

/// Parse a sentencepiece ModelProto: field 1 is a repeated SentencePiece{1: piece, 2: score, 3: type}
fn load_pieces(path: &Path) -> Result<Vec<Piece>> {
    let data = std::fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    let mut pieces = Vec::new();
    let mut r = ProtoReader(&data);
    while let Some((field, value)) = r.next()? {
        let (1, Wire::Bytes(msg)) = (field, value) else { continue };
        let (mut text, mut kind) = (String::new(), 1u64);
        let mut m = ProtoReader(msg);
        while let Some((f, v)) = m.next()? {
            match (f, v) {
                (1, Wire::Bytes(b)) => text = String::from_utf8_lossy(b).into_owned(),
                (3, Wire::Varint(t)) => kind = t,
                _ => {}
            }
        }
        let kind = match kind {
            2 => PieceKind::Unknown,
            3 => PieceKind::Control,
            6 => {
                let hex = text.trim_start_matches("<0x").trim_end_matches('>');
                PieceKind::Byte(u8::from_str_radix(hex, 16).unwrap_or(b'?'))
            }
            _ => PieceKind::Normal,
        };
        pieces.push(Piece { text, kind });
    }
    if pieces.is_empty() {
        bail!("no pieces in sentencepiece model: {}", path.display());
    }
    Ok(pieces)
}

enum Wire<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
    Other,
}

struct ProtoReader<'a>(&'a [u8]);

impl<'a> ProtoReader<'a> {
    fn varint(&mut self) -> Result<u64> {
        let mut v = 0u64;
        for shift in (0..64).step_by(7) {
            let (&b, rest) = self.0.split_first().ok_or_else(|| anyhow!("truncated protobuf"))?;
            self.0 = rest;
            v |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 {
                return Ok(v);
            }
        }
        bail!("protobuf varint too long")
    }

    fn next(&mut self) -> Result<Option<(u64, Wire<'a>)>> {
        if self.0.is_empty() {
            return Ok(None);
        }
        let key = self.varint()?;
        let value = match key & 7 {
            0 => Wire::Varint(self.varint()?),
            1 | 5 => {
                let n = if key & 7 == 1 { 8 } else { 4 };
                if self.0.len() < n {
                    bail!("truncated protobuf");
                }
                self.0 = &self.0[n..];
                Wire::Other
            }
            2 => {
                let n = self.varint()? as usize;
                if self.0.len() < n {
                    bail!("truncated protobuf");
                }
                let (b, rest) = self.0.split_at(n);
                self.0 = rest;
                Wire::Bytes(b)
            }
            w => bail!("unsupported protobuf wire type {w}"),
        };
        Ok(Some((key >> 3, value)))
    }
}
