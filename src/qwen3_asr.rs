//! Qwen3-ASR: Whisper-style audio encoder + Qwen3 text decoder, greedy decoding.
//!
//! A layer-by-layer port of mlx-audio 0.5.9's `stt/models/qwen3_asr` (including how 8-bit quantized weights are
//! loaded); with the same MLX version it generates the same tokens as the Python version. Context biasing
//! (hotwords) is injected via the system prompt.

use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};
use mlx_rs::fast::{self, ScaledDotProductAttentionMask};
use mlx_rs::ops::indexing::IndexOp;
use mlx_rs::{nn as mnn, ops, transforms, Array, Dtype};
use serde::Deserialize;
use tokenizers::decoders::byte_level::ByteLevel as ByteLevelDecoder;
use tokenizers::models::bpe::BPE;
use tokenizers::normalizers::unicode::NFC;
use tokenizers::pre_tokenizers::byte_level::ByteLevel;
use tokenizers::pre_tokenizers::sequence::Sequence;
use tokenizers::pre_tokenizers::split::{Split, SplitPattern};
use tokenizers::{AddedToken, SplitDelimiterBehavior, Tokenizer};

use crate::features::whisper_log_mel;
use crate::nn::{Embedding, Linear, Quant, Weights};

const SAMPLE_RATE: usize = 16000;
/// Audio longer than 20 minutes is split at low-energy points (matches mlx-audio's default chunk_duration)
const CHUNK_SECONDS: usize = 1200;
const MAX_TOKENS: usize = 8192;
/// Per-chunk token budget: a fixed allowance (language prefix, short clips) plus tokens per second of audio. Real
/// speech stays well under 10 tokens/s; a decoder stuck repeating itself would otherwise run to MAX_TOKENS, which
/// takes minutes and holds the inference queue
const BUDGET_BASE_TOKENS: usize = 64;
const BUDGET_TOKENS_PER_SECOND: usize = 20;
const PREFILL_STEP: usize = 2048;

#[derive(Deserialize)]
struct RawConfig {
    thinker_config: ThinkerConfig,
    quantization: Option<QuantConfig>,
    #[serde(default)]
    support_languages: Vec<String>,
}

#[derive(Deserialize)]
struct ThinkerConfig {
    audio_config: AudioConfig,
    text_config: TextConfig,
    #[serde(default = "default_audio_token")]
    audio_token_id: u32,
}

fn default_audio_token() -> u32 {
    151676
}

#[derive(Deserialize)]
struct QuantConfig {
    group_size: i32,
    bits: i32,
}

#[derive(Deserialize, Clone)]
struct AudioConfig {
    d_model: i32,
    encoder_attention_heads: i32,
    encoder_layers: usize,
    num_mel_bins: usize,
    max_source_positions: i32,
    n_window: usize,
    n_window_infer: usize,
}

#[derive(Deserialize, Clone)]
struct TextConfig {
    num_hidden_layers: usize,
    num_attention_heads: i32,
    num_key_value_heads: i32,
    head_dim: i32,
    rms_norm_eps: f32,
    rope_theta: f32,
}

pub struct Transcript {
    pub text: String,
    /// Detected language name (e.g. "Chinese"); equals the requested language when the caller set one
    pub language: Option<String>,
}

pub struct Qwen3Asr {
    encoder: AudioEncoder,
    decoder: TextDecoder,
    tokenizer: Tokenizer,
    languages: Vec<String>,
    audio_token: u32,
    eos: Vec<u32>,
}

impl Qwen3Asr {
    pub fn load(dir: &Path) -> Result<Self> {
        let raw: RawConfig = serde_json::from_slice(&std::fs::read(dir.join("config.json"))?)
            .context("failed to parse Qwen3-ASR config.json")?;
        let quant = raw.quantization.map(|q| Quant { group_size: q.group_size, bits: q.bits });
        let mut w = Weights::load(dir, quant)?;
        let encoder = AudioEncoder::load(&mut w, &raw.thinker_config.audio_config)?;
        let decoder = TextDecoder::load(&mut w, &raw.thinker_config.text_config)?;
        // Tied embeddings, so there is no separate lm_head; any leftover weights mean the key mapping missed something
        w.take_opt("lm_head.weight");
        let left = w.leftover();
        if !left.is_empty() {
            bail!("{} weights were not used, e.g. {}", left.len(), left[0]);
        }
        let tokenizer = load_tokenizer(dir)?;
        let eos = ["<|im_end|>", "<|endoftext|>"].iter().filter_map(|t| tokenizer.token_to_id(t)).collect();
        Ok(Self {
            encoder,
            decoder,
            tokenizer,
            languages: raw.support_languages,
            audio_token: raw.thinker_config.audio_token_id,
            eos,
        })
    }

    /// `language` is an English language name (e.g. "Chinese") or None to auto-detect; `system_prompt` is the context
    /// prompt (including hotwords)
    pub fn transcribe(&self, pcm: &[f32], language: Option<&str>, system_prompt: Option<&str>) -> Result<Transcript> {
        let mut texts = Vec::new();
        let mut detected = None;
        for chunk in split_chunks(pcm) {
            let (text, lang) = self.transcribe_chunk(&chunk, language, system_prompt)?;
            texts.push(text);
            detected = detected.or(lang);
        }
        Ok(Transcript { text: texts.join(" ").trim().to_string(), language: detected })
    }

    /// Encode audio: returns [audio tokens, hidden] (already evaluated)
    pub fn encode(&self, pcm: &[f32]) -> Result<Array> {
        let (mel, frames) = whisper_log_mel(pcm, self.encoder.n_mels);
        let audio = self.encoder.forward(&mel, frames)?;
        transforms::eval([&audio])?;
        Ok(audio)
    }

    fn transcribe_chunk(&self, pcm: &[f32], language: Option<&str>, system_prompt: Option<&str>) -> Result<(String, Option<String>)> {
        let audio = self.encode(pcm)?;
        let n_audio = audio.dim(0) as usize;

        let ids = self.build_prompt(n_audio, language, system_prompt)?;
        let budget = (BUDGET_BASE_TOKENS + BUDGET_TOKENS_PER_SECOND * pcm.len() / SAMPLE_RATE).min(MAX_TOKENS);
        let tokens = self.generate(&ids, &audio, budget)?;
        let text = self
            .tokenizer
            .decode(&tokens, true)
            .map_err(|e| anyhow!("failed to decode tokens: {e}"))?;
        if language.is_some() {
            return Ok((text, language.map(str::to_string)));
        }
        // When auto-detecting, the model first outputs "language Chinese<asr_text>" followed by the text
        match (text.strip_prefix("language "), text.find("<asr_text>")) {
            (Some(_), Some(pos)) => {
                let lang = text["language ".len()..pos].trim().to_string();
                let body = text[pos + "<asr_text>".len()..].to_string();
                Ok((body, (!lang.is_empty() && lang != "None").then_some(lang)))
            }
            _ => Ok((text, None)),
        }
    }

    pub fn build_prompt(&self, n_audio: usize, language: Option<&str>, system_prompt: Option<&str>) -> Result<Vec<u32>> {
        let system = system_prompt.filter(|s| !s.is_empty()).map(|s| format!("{s}\n")).unwrap_or_default();
        let prefix = match language {
            Some(lang) => {
                // Match case-insensitively to a language name the model supports
                let name = self
                    .languages
                    .iter()
                    .find(|l| l.eq_ignore_ascii_case(lang))
                    .map(String::as_str)
                    .unwrap_or(lang);
                format!("language {name}<asr_text>")
            }
            None => String::new(),
        };
        let prompt = format!(
            "<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n<|audio_start|>{}<|audio_end|><|im_end|>\n<|im_start|>assistant\n{prefix}",
            "<|audio_pad|>".repeat(n_audio)
        );
        let enc = self.tokenizer.encode(prompt, false).map_err(|e| anyhow!("tokenization failed: {e}"))?;
        Ok(enc.get_ids().to_vec())
    }

    /// Greedy decoding: prefill the KV cache in chunks with every prompt token except the last, then generate token by token
    /// Generation stops at `max_tokens` with a warning, keeping what was decoded so far
    fn generate(&self, ids: &[u32], audio: &Array, max_tokens: usize) -> Result<Vec<u32>> {
        let total = ids.len();
        let ids_arr = Array::from_slice(&ids.iter().map(|&i| i as i32).collect::<Vec<_>>(), &[1, total as i32]);
        let embeds = self.decoder.embed.forward(&ids_arr)?;

        // Replace the audio placeholders (contiguous) with the encoder output
        let start = ids.iter().position(|&t| t == self.audio_token).ok_or_else(|| anyhow!("no audio placeholder in the prompt"))?;
        let count = ids[start..].iter().take_while(|&&t| t == self.audio_token).count();
        if count != audio.dim(0) as usize {
            bail!("{count} audio placeholders but the encoder produced {} frames", audio.dim(0));
        }
        let audio = audio.as_dtype(embeds.dtype())?.expand_dims(0)?;
        let mut embeds = ops::concatenate(
            &[
                embeds.index((.., ..start as i32, ..)),
                audio,
                embeds.index((.., (start + count) as i32.., ..)),
            ],
            1,
        )?;

        let mut cache: Vec<KvCache> = (0..self.decoder.layers.len()).map(|_| KvCache::default()).collect();
        let mut done = 0;
        while total - done > 1 {
            let n = PREFILL_STEP.min(total - done - 1);
            let h = self.decoder.forward(&embeds.index((.., ..n as i32, ..)), &mut cache)?;
            let states: Vec<&Array> = cache.iter().flat_map(|c| c.k.iter().chain(c.v.iter())).collect();
            transforms::eval(states)?;
            drop(h);
            embeds = embeds.index((.., n as i32.., ..));
            done += n;
        }

        let mut token = self.step(&embeds, &mut cache)?;
        let mut out = Vec::new();
        loop {
            let t = token.try_item_exact::<u32>()?;
            if self.eos.contains(&t) {
                break;
            }
            if out.len() >= max_tokens {
                log::warn!("decoding stopped at the {max_tokens}-token budget for this audio; the model was probably repeating itself");
                break;
            }
            out.push(t);
            let x = self.decoder.embed.forward(&Array::from_slice(&[t as i32], &[1, 1]))?;
            token = self.step(&x, &mut cache)?;
        }
        Ok(out)
    }

    /// One forward step, then the greedy token at the last position (subtract logsumexp before argmax to match the
    /// Python version bit for bit)
    fn step(&self, x: &Array, cache: &mut [KvCache]) -> Result<Array> {
        let h = self.decoder.forward(x, cache)?;
        let last = h.index((.., -1, ..));
        let logits = self.decoder.embed.as_linear(&last)?;
        let logprobs = logits.subtract(logits.logsumexp_axis(-1, true)?)?;
        let token = ops::indexing::argmax_axis(&logprobs, -1, None)?;
        transforms::eval([&token])?;
        Ok(token.reshape(&[])?.as_dtype(Dtype::Uint32)?)
    }
}

/// Build the Qwen2 BPE tokenizer: the model directory only has vocab.json + merges.txt, so assemble it following
/// Qwen2TokenizerFast's configuration
fn load_tokenizer(dir: &Path) -> Result<Tokenizer> {
    const PATTERN: &str = r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+";
    let vocab = dir.join("vocab.json");
    let merges = dir.join("merges.txt");
    let bpe = BPE::from_file(&vocab.to_string_lossy(), &merges.to_string_lossy())
        .build()
        .map_err(|e| anyhow!("failed to load BPE vocabulary: {e}"))?;
    let mut tk = Tokenizer::new(bpe);
    tk.with_normalizer(Some(NFC));
    let split = Split::new(SplitPattern::Regex(PATTERN.into()), SplitDelimiterBehavior::Isolated, false)
        .map_err(|e| anyhow!("invalid pre-tokenizer regex: {e}"))?;
    tk.with_pre_tokenizer(Some(Sequence::new(vec![split.into(), ByteLevel::new(false, false, false).into()])));
    tk.with_decoder(Some(ByteLevelDecoder::default()));

    // Add extra tokens in id order so they get the same ids as in tokenizer_config.json
    #[derive(Deserialize)]
    struct Added {
        content: String,
        special: bool,
    }
    #[derive(Deserialize)]
    struct TokCfg {
        added_tokens_decoder: std::collections::BTreeMap<String, Added>,
    }
    let cfg: TokCfg = serde_json::from_slice(&std::fs::read(dir.join("tokenizer_config.json"))?)?;
    let mut added: Vec<(u32, Added)> = cfg
        .added_tokens_decoder
        .into_iter()
        .map(|(id, t)| Ok((id.parse::<u32>()?, t)))
        .collect::<Result<_>>()?;
    added.sort_by_key(|(id, _)| *id);
    for (id, t) in added {
        let tok = AddedToken::from(t.content.clone(), t.special).normalized(false);
        if t.special {
            tk.add_special_tokens(&[tok]);
        } else {
            tk.add_tokens(&[tok]);
        }
        if tk.token_to_id(&t.content) != Some(id) {
            bail!("added token {} should have id {id}, got {:?}", t.content, tk.token_to_id(&t.content));
        }
    }
    Ok(tk)
}

struct EncoderLayer {
    q: Linear,
    k: Linear,
    v: Linear,
    o: Linear,
    ln1: (Array, Array),
    fc1: Linear,
    fc2: Linear,
    ln2: (Array, Array),
}

struct AudioEncoder {
    convs: Vec<(Array, Array)>,
    conv_out: Linear,
    pos: Array,
    layers: Vec<EncoderLayer>,
    ln_post: (Array, Array),
    proj1: Linear,
    proj2: Linear,
    heads: i32,
    d_model: i32,
    n_mels: usize,
    chunk: usize,
    infer_ratio: usize,
}

fn layer_norm(w: &mut Weights, prefix: &str) -> Result<(Array, Array)> {
    Ok((w.take(&format!("{prefix}.weight"))?, w.take(&format!("{prefix}.bias"))?))
}

/// Frame count after convolutional downsampling: every 100 frames yield 13, the remainder goes through three
/// stride-2 steps (with Python's floor division)
fn after_cnn(len: usize) -> usize {
    let f = |x: i64| (x - 1).div_euclid(2) + 1;
    let rem = (len % 100) as i64;
    (f(f(f(rem))) + (len / 100) as i64 * 13) as usize
}

impl AudioEncoder {
    fn load(w: &mut Weights, c: &AudioConfig) -> Result<Self> {
        let p = "audio_tower";
        let convs = (1..=3)
            .map(|i| Ok((w.take(&format!("{p}.conv2d{i}.weight"))?, w.take(&format!("{p}.conv2d{i}.bias"))?)))
            .collect::<Result<_>>()?;
        let layers = (0..c.encoder_layers)
            .map(|i| {
                let l = format!("{p}.layers.{i}");
                Ok(EncoderLayer {
                    q: w.linear(&format!("{l}.self_attn.q_proj"))?,
                    k: w.linear(&format!("{l}.self_attn.k_proj"))?,
                    v: w.linear(&format!("{l}.self_attn.v_proj"))?,
                    o: w.linear(&format!("{l}.self_attn.out_proj"))?,
                    ln1: layer_norm(w, &format!("{l}.self_attn_layer_norm"))?,
                    fc1: w.linear(&format!("{l}.fc1"))?,
                    fc2: w.linear(&format!("{l}.fc2"))?,
                    ln2: layer_norm(w, &format!("{l}.final_layer_norm"))?,
                })
            })
            .collect::<Result<_>>()?;
        Ok(Self {
            convs,
            conv_out: w.linear(&format!("{p}.conv_out"))?,
            pos: sinusoid(c.max_source_positions, c.d_model)?,
            layers,
            ln_post: layer_norm(w, &format!("{p}.ln_post"))?,
            proj1: w.linear(&format!("{p}.proj1"))?,
            proj2: w.linear(&format!("{p}.proj2"))?,
            heads: c.encoder_attention_heads,
            d_model: c.d_model,
            n_mels: c.num_mel_bins,
            chunk: c.n_window * 2,
            infer_ratio: c.n_window_infer / (c.n_window * 2),
        })
    }

    /// `mel` is laid out [n_mels][frames]; returns [audio tokens, output_dim]
    fn forward(&self, mel: &[f32], frames: usize) -> Result<Array> {
        // Split into 100-frame chunks, zero-pad to equal length and run the convolutions on them together
        let mut lens = vec![self.chunk; frames / self.chunk];
        if frames % self.chunk != 0 {
            lens.push(frames % self.chunk);
        }
        let max_len = *lens.iter().max().ok_or_else(|| anyhow!("audio is too short"))?;
        let mut buf = vec![0f32; lens.len() * self.n_mels * max_len];
        let mut pos = 0;
        for (c, &len) in lens.iter().enumerate() {
            for m in 0..self.n_mels {
                let dst = (c * self.n_mels + m) * max_len;
                buf[dst..dst + len].copy_from_slice(&mel[m * frames + pos..m * frames + pos + len]);
            }
            pos += len;
        }
        let mut x = Array::from_slice(&buf, &[lens.len() as i32, self.n_mels as i32, max_len as i32, 1]);
        for (wt, b) in &self.convs {
            x = mnn::gelu(ops::conv2d(&x, wt, (2, 2), (1, 1), None, None)?.add(b)?)?;
        }
        let (b, f, t, c) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3));
        let x = x.transpose_axes(&[0, 2, 3, 1])?.reshape(&[b, t, c * f])?;
        let x = self.conv_out.forward(&x)?.add(self.pos.index((..t, ..)).expand_dims(0)?)?;

        // Drop the invalid frames produced by padding and concatenate into one sequence
        let valid: Vec<usize> = lens.iter().map(|&l| after_cnn(l)).collect();
        let parts: Vec<Array> = valid.iter().enumerate().map(|(i, &v)| x.index((i as i32, ..v as i32, ..))).collect();
        let mut h = ops::concatenate(&parts, 0)?;
        let n = h.dim(0);

        // Block-diagonal attention: one block per `window` frames (8 seconds), frames attend only within their block
        let window = valid.iter().max().copied().unwrap_or(1) * self.infer_ratio;
        let total = after_cnn(frames);
        if total != n as usize {
            bail!("encoder frame count mismatch: {total} != {n}");
        }
        let block: Vec<i32> = (0..total).map(|i| (i / window) as i32).collect();
        let block = Array::from_slice(&block, &[n]);
        let same = block.reshape(&[n, 1])?.eq(&block.reshape(&[1, n])?)?;
        let zero = Array::from_f32(0.0).as_dtype(h.dtype())?;
        let neg = Array::from_f32(-1e9).as_dtype(h.dtype())?;
        let mask = ops::select(&same, &zero, &neg)?.reshape(&[1, 1, n, n])?;

        h = h.expand_dims(0)?;
        let head_dim = self.d_model / self.heads;
        let scale = (head_dim as f32).powf(-0.5);
        for l in &self.layers {
            let r = h.clone();
            let y = fast::layer_norm(&h, &l.ln1.0, &l.ln1.1, 1e-5)?;
            let split = |a: Array| a.reshape(&[1, n, self.heads, head_dim])?.transpose_axes(&[0, 2, 1, 3]);
            let q = split(l.q.forward(&y)?.multiply(Array::from_f32(scale))?)?;
            let k = split(l.k.forward(&y)?)?;
            let v = split(l.v.forward(&y)?)?;
            let a = fast::scaled_dot_product_attention(&q, &k, &v, 1.0, ScaledDotProductAttentionMask::Array(&mask), None)?;
            let a = a.transpose_axes(&[0, 2, 1, 3])?.reshape(&[1, n, self.d_model])?;
            h = r.add(l.o.forward(&a)?)?;
            let r = h.clone();
            let y = fast::layer_norm(&h, &l.ln2.0, &l.ln2.1, 1e-5)?;
            let y = l.fc2.forward(&mnn::gelu(l.fc1.forward(&y)?)?)?;
            h = r.add(y)?;
        }
        let h = h.index(0);
        let h = fast::layer_norm(&h, &self.ln_post.0, &self.ln_post.1, 1e-5)?;
        self.proj2.forward(&mnn::gelu(self.proj1.forward(&h)?)?)
    }
}

/// Whisper-style sinusoidal position encoding [length, channels]: sin in the first half, cos in the second
fn sinusoid(length: i32, channels: i32) -> Result<Array> {
    let half = channels / 2;
    // Compute the coefficients in f64, then convert to f32, matching Python
    let inc = (10000f64.ln() / (half - 1) as f64) as f32;
    let inv = ops::arange::<_, f32>(None, half, None)?.multiply(Array::from_f32(-inc))?.exp()?;
    let pos = ops::arange::<_, f32>(None, length, None)?.reshape(&[length, 1])?;
    let t = pos.multiply(inv.reshape(&[1, half])?)?;
    let out = ops::concatenate(&[t.sin()?, t.cos()?], 1)?;
    transforms::eval([&out])?;
    Ok(out)
}

struct DecoderLayer {
    q: Linear,
    k: Linear,
    v: Linear,
    o: Linear,
    q_norm: Array,
    k_norm: Array,
    in_norm: Array,
    post_norm: Array,
    gate: Linear,
    up: Linear,
    down: Linear,
}

struct TextDecoder {
    embed: Embedding,
    layers: Vec<DecoderLayer>,
    norm: Array,
    heads: i32,
    kv_heads: i32,
    head_dim: i32,
    eps: f32,
    theta: f32,
}

#[derive(Default)]
struct KvCache {
    k: Option<Array>,
    v: Option<Array>,
    offset: i32,
}

impl KvCache {
    fn update(&mut self, k: Array, v: Array) -> Result<(Array, Array)> {
        let (k, v) = match (self.k.take(), self.v.take()) {
            (Some(pk), Some(pv)) => (ops::concatenate(&[pk, k], 2)?, ops::concatenate(&[pv, v], 2)?),
            _ => (k, v),
        };
        self.offset = k.dim(2);
        self.k = Some(k.clone());
        self.v = Some(v.clone());
        Ok((k, v))
    }
}

impl TextDecoder {
    fn load(w: &mut Weights, c: &TextConfig) -> Result<Self> {
        let layers = (0..c.num_hidden_layers)
            .map(|i| {
                let l = format!("model.layers.{i}");
                Ok(DecoderLayer {
                    q: w.linear(&format!("{l}.self_attn.q_proj"))?,
                    k: w.linear(&format!("{l}.self_attn.k_proj"))?,
                    v: w.linear(&format!("{l}.self_attn.v_proj"))?,
                    o: w.linear(&format!("{l}.self_attn.o_proj"))?,
                    q_norm: w.take(&format!("{l}.self_attn.q_norm.weight"))?,
                    k_norm: w.take(&format!("{l}.self_attn.k_norm.weight"))?,
                    in_norm: w.take(&format!("{l}.input_layernorm.weight"))?,
                    post_norm: w.take(&format!("{l}.post_attention_layernorm.weight"))?,
                    gate: w.linear(&format!("{l}.mlp.gate_proj"))?,
                    up: w.linear(&format!("{l}.mlp.up_proj"))?,
                    down: w.linear(&format!("{l}.mlp.down_proj"))?,
                })
            })
            .collect::<Result<_>>()?;
        Ok(Self {
            embed: w.embedding("model.embed_tokens")?,
            layers,
            norm: w.take("model.norm.weight")?,
            heads: c.num_attention_heads,
            kv_heads: c.num_key_value_heads,
            head_dim: c.head_dim,
            eps: c.rms_norm_eps,
            theta: c.rope_theta,
        })
    }

    /// x: [1, L, hidden]; returns the hidden states after the final norm
    fn forward(&self, x: &Array, cache: &mut [KvCache]) -> Result<Array> {
        let (b, l) = (x.dim(0), x.dim(1));
        let scale = (self.head_dim as f32).powf(-0.5);
        let mut x = x.clone();
        for (layer, c) in self.layers.iter().zip(cache.iter_mut()) {
            let h = fast::rms_norm(&x, Some(&layer.in_norm), self.eps)?;
            let q = layer.q.forward(&h)?.reshape(&[b, l, self.heads, self.head_dim])?;
            let k = layer.k.forward(&h)?.reshape(&[b, l, self.kv_heads, self.head_dim])?;
            let v = layer.v.forward(&h)?.reshape(&[b, l, self.kv_heads, self.head_dim])?;
            let q = fast::rms_norm(&q, Some(&layer.q_norm), self.eps)?.transpose_axes(&[0, 2, 1, 3])?;
            let k = fast::rms_norm(&k, Some(&layer.k_norm), self.eps)?.transpose_axes(&[0, 2, 1, 3])?;
            let v = v.transpose_axes(&[0, 2, 1, 3])?;
            // With audio-only input the three MRoPE position streams are identical, so it reduces to plain RoPE
            let q = fast::rope(&q, self.head_dim, false, self.theta, 1.0, c.offset, None)?;
            let k = fast::rope(&k, self.head_dim, false, self.theta, 1.0, c.offset, None)?;
            let (k, v) = c.update(k, v)?;
            let mask = (l > 1).then_some(ScaledDotProductAttentionMask::Causal);
            let a = fast::scaled_dot_product_attention(&q, &k, &v, scale, mask, None)?;
            let a = a.transpose_axes(&[0, 2, 1, 3])?.reshape(&[b, l, -1])?;
            x = x.add(layer.o.forward(&a)?)?;
            let h = fast::rms_norm(&x, Some(&layer.post_norm), self.eps)?;
            let g = mnn::silu(layer.gate.forward(&h)?)?.multiply(layer.up.forward(&h)?)?;
            x = x.add(layer.down.forward(&g)?)?;
        }
        Ok(fast::rms_norm(&x, Some(&self.norm), self.eps)?)
    }
}

/// Split very long audio at low-energy points; pad anything shorter than 1 second to 1 second (same as mlx-audio
/// split_audio_into_chunks)
fn split_chunks(pcm: &[f32]) -> Vec<Vec<f32>> {
    let min = SAMPLE_RATE;
    let pad = |c: &[f32]| {
        let mut v = c.to_vec();
        if v.len() < min {
            v.resize(min, 0.0);
        }
        v
    };
    let max = CHUNK_SECONDS * SAMPLE_RATE;
    if pcm.len() <= max {
        return vec![pad(pcm)];
    }
    let search = 5 * SAMPLE_RATE;
    let win = SAMPLE_RATE / 10;
    let mut out = Vec::new();
    let mut start = 0;
    while start < pcm.len() {
        let end = (start + max).min(pcm.len());
        if end >= pcm.len() {
            out.push(pad(&pcm[start..]));
            break;
        }
        let (s0, s1) = (start.max(end.saturating_sub(search)), (end + search).min(pcm.len()));
        let region = &pcm[s0..s1];
        let mut cut = end;
        if region.len() > win {
            // Cut where the sliding-window energy is lowest
            let mut acc: f64 = region[..win].iter().map(|&x| (x as f64).powi(2)).sum();
            let (mut best, mut best_i) = (acc, 0);
            for i in 1..=region.len() - win {
                acc += (region[i + win - 1] as f64).powi(2) - (region[i - 1] as f64).powi(2);
                if acc < best {
                    best = acc;
                    best_i = i;
                }
            }
            cut = s0 + best_i + win / 2;
        }
        let cut = cut.max(start + SAMPLE_RATE);
        out.push(pad(&pcm[start..cut]));
        start = cut;
    }
    out
}
