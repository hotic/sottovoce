//! Small components shared by the models: weight map, linear and embedding layers, model directory resolution.
//!
//! Inference only, without mlx-rs's Module system: weights go into a map and the forward pass is written by hand.
//! Operator choices match the MLX Python nn module (addmm for Linear, fast ops for norms), so with the same MLX
//! version the output stays bit-for-bit close to mlx-audio.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, bail, Context, Result};
use mlx_rs::{ops, Array};

/// Quantization parameters: group size and bit width (64 / 8 for mlx-community 8-bit models)
#[derive(Clone, Copy, Debug)]
pub struct Quant {
    pub group_size: i32,
    pub bits: i32,
}

/// safetensors weight map; weights are removed as they are taken, so unused ones can be checked at the end
pub struct Weights {
    map: HashMap<String, Array>,
    quant: Option<Quant>,
}

impl Weights {
    pub fn load(dir: &Path, quant: Option<Quant>) -> Result<Self> {
        let mut map = HashMap::new();
        let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
            .with_context(|| format!("failed to read model directory: {}", dir.display()))?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "safetensors"))
            .collect();
        files.sort();
        if files.is_empty() {
            bail!("no safetensors files in model directory: {}", dir.display());
        }
        for f in files {
            let part = Array::load_safetensors(&f).map_err(|e| anyhow!("failed to load {}: {e}", f.display()))?;
            map.extend(part);
        }
        Ok(Self { map, quant })
    }

    pub fn take(&mut self, key: &str) -> Result<Array> {
        self.map.remove(key).ok_or_else(|| anyhow!("missing weight: {key}"))
    }

    pub fn take_opt(&mut self, key: &str) -> Option<Array> {
        self.map.remove(key)
    }

    /// Plain or quantized linear layer: quantized if `{prefix}.scales` exists
    pub fn linear(&mut self, prefix: &str) -> Result<Linear> {
        let weight = self.take(&format!("{prefix}.weight"))?;
        let bias = self.take_opt(&format!("{prefix}.bias"));
        match self.take_opt(&format!("{prefix}.scales")) {
            Some(scales) => {
                let quant = self.quant.ok_or_else(|| anyhow!("{prefix} is quantized, but the config has no quantization section"))?;
                let biases = self.take(&format!("{prefix}.biases"))?;
                Ok(Linear::Quantized { weight, scales, biases, bias, quant })
            }
            None => Ok(Linear::Dense { weight, bias }),
        }
    }

    pub fn embedding(&mut self, prefix: &str) -> Result<Embedding> {
        Ok(Embedding(self.linear(prefix)?))
    }

    /// Names of weights left unused after loading, to catch key-mapping mistakes
    pub fn leftover(&self) -> Vec<&str> {
        let mut keys: Vec<&str> = self.map.keys().map(String::as_str).collect();
        keys.sort();
        keys
    }
}

pub enum Linear {
    Dense { weight: Array, bias: Option<Array> },
    Quantized { weight: Array, scales: Array, biases: Array, bias: Option<Array>, quant: Quant },
}

impl Linear {
    pub fn forward(&self, x: &Array) -> Result<Array> {
        Ok(match self {
            // Same as mlx.nn.Linear: use addmm(bias, x, W^T) when there is a bias
            Linear::Dense { weight, bias: Some(b) } => ops::addmm(b, x, weight.t(), None, None)?,
            Linear::Dense { weight, bias: None } => ops::matmul(x, weight.t())?,
            Linear::Quantized { weight, scales, biases, bias, quant } => {
                let y = ops::quantized_matmul(x, weight, scales, biases, true, quant.group_size, quant.bits)?;
                match bias {
                    Some(b) => y.add(b)?,
                    None => y,
                }
            }
        })
    }
}

/// Embedding layer; the quantized version gathers rows and then dequantizes (same as mlx.nn.QuantizedEmbedding)
pub struct Embedding(Linear);

impl Embedding {
    pub fn forward(&self, ids: &Array) -> Result<Array> {
        Ok(match &self.0 {
            Linear::Dense { weight, .. } => weight.take_axis(ids, 0)?,
            Linear::Quantized { weight, scales, biases, quant, .. } => ops::dequantize(
                weight.take_axis(ids, 0)?,
                scales.take_axis(ids, 0)?,
                &biases.take_axis(ids, 0)?,
                quant.group_size,
                quant.bits,
            )?,
        })
    }

    /// Output head with tied weights: x @ E^T
    pub fn as_linear(&self, x: &Array) -> Result<Array> {
        Ok(match &self.0 {
            Linear::Dense { weight, .. } => ops::matmul(x, weight.t())?,
            Linear::Quantized { weight, scales, biases, quant, .. } => {
                ops::quantized_matmul(x, weight, scales, biases, true, quant.group_size, quant.bits)?
            }
        })
    }
}

/// Resolve a model id to a local directory: existing paths are used as is, otherwise look it up in the Hugging Face
/// cache layout `<cache>/models--org--name/snapshots/<refs/main>`. The server runs offline and never downloads.
pub fn resolve_model_dir(id: &str) -> Result<PathBuf> {
    let p = PathBuf::from(id);
    if p.is_dir() {
        return Ok(p);
    }
    let cache = std::env::var_os("HF_HUB_CACHE")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HF_HOME").map(|h| PathBuf::from(h).join("hub")))
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache/huggingface/hub")))
        .ok_or_else(|| anyhow!("Hugging Face cache directory not found"))?;
    let repo = cache.join(format!("models--{}", id.replace('/', "--")));
    let rev = std::fs::read_to_string(repo.join("refs/main"))
        .with_context(|| format!("model {id} not found locally ({}); download it first with huggingface-cli download", repo.display()))?;
    let dir = repo.join("snapshots").join(rev.trim());
    if !dir.is_dir() {
        bail!("model snapshot directory does not exist: {}", dir.display());
    }
    Ok(dir)
}
