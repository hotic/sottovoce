//! Recognition engine: models are loaded once and all inference runs serially on one dedicated thread.
//!
//! Besides the main model, an optional preview model (SenseVoice-Small by default, a few tens of ms per call)
//! lets dictation clients show text while the user is still speaking; the final transcript after release still
//! comes from the main model. Both models share the same thread.
//!
//! MLX streams are bound to threads, so a model must run inference on the thread that loaded it.
//! There is only one GPU anyway, so serial execution doubles as the request queue (first come, first served).

use std::sync::mpsc;
use std::time::Instant;

use anyhow::{anyhow, Result};
use tokio::sync::oneshot;

use crate::audio::SAMPLE_RATE;
use crate::nn::resolve_model_dir;
use crate::qwen3_asr::Qwen3Asr;
use crate::sensevoice::SenseVoice;

/// The OpenAI API passes ISO codes; Qwen3-ASR expects English language names
const LANGUAGES: &[(&str, &str)] = &[
    ("zh", "Chinese"),
    ("cmn", "Chinese"),
    ("yue", "Cantonese"),
    ("en", "English"),
    ("ja", "Japanese"),
    ("ko", "Korean"),
    ("fr", "French"),
    ("de", "German"),
    ("es", "Spanish"),
    ("ru", "Russian"),
    ("it", "Italian"),
    ("pt", "Portuguese"),
];

pub struct Output {
    pub text: String,
    pub language: Option<String>,
    pub audio_s: f64,
    pub elapsed_s: f64,
}

pub struct Request {
    pub pcm: Vec<f32>,
    pub language: Option<String>,
    pub prompt: Option<String>,
    pub hotwords: Vec<String>,
    pub preview: bool,
}

type Job = (Request, oneshot::Sender<Result<Output>>);

pub struct Engine {
    pub model_id: String,
    pub has_preview: bool,
    tx: mpsc::Sender<Job>,
}

struct Worker {
    main: Qwen3Asr,
    preview: Option<SenseVoice>,
    default_language: Option<String>,
}

impl Engine {
    /// Start the inference thread and load the models on it; returns once loading succeeds (or fails)
    pub fn start(model_id: &str, preview_id: Option<&str>, default_language: Option<String>) -> Result<Self> {
        let (tx, rx) = mpsc::channel::<Job>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<bool>>();
        let (model, preview) = (model_id.to_string(), preview_id.map(str::to_string));
        std::thread::Builder::new().name("asr".into()).spawn(move || {
            let worker = match Worker::load(&model, preview.as_deref(), default_language) {
                Ok(w) => w,
                Err(e) => {
                    let _ = ready_tx.send(Err(e));
                    return;
                }
            };
            let _ = ready_tx.send(Ok(worker.preview.is_some()));
            for (req, reply) in rx {
                let _ = reply.send(worker.run(req));
                // Release MLX's buffer cache so idle memory stays low
                let _ = mlx_rs::memory::clear_cache();
            }
        })?;
        let has_preview = ready_rx.recv().map_err(|_| anyhow!("inference thread exited unexpectedly"))??;
        Ok(Self { model_id: model_id.to_string(), has_preview, tx })
    }

    pub async fn transcribe(&self, req: Request) -> Result<Output> {
        let (reply, rx) = oneshot::channel();
        self.tx.send((req, reply)).map_err(|_| anyhow!("inference thread has exited"))?;
        rx.await.map_err(|_| anyhow!("inference thread has exited"))?
    }
}

impl Worker {
    fn load(model_id: &str, preview_id: Option<&str>, default_language: Option<String>) -> Result<Self> {
        let silence = vec![0f32; SAMPLE_RATE];
        let t = Instant::now();
        let main = Qwen3Asr::load(&resolve_model_dir(model_id)?)?;
        // Warm up once so the first request does not pay for kernel compilation
        main.transcribe(&silence, None, None)?;
        log::info!("model loaded: {model_id} ({:.1}s)", t.elapsed().as_secs_f64());
        let preview = match preview_id {
            Some(id) => {
                let t = Instant::now();
                let m = SenseVoice::load(&resolve_model_dir(id)?)?;
                m.transcribe(&silence, "auto")?;
                log::info!("preview model loaded: {id} ({:.1}s)", t.elapsed().as_secs_f64());
                Some(m)
            }
            None => None,
        };
        Ok(Self { main, preview, default_language })
    }

    fn run(&self, req: Request) -> Result<Output> {
        let audio_s = req.pcm.len() as f64 / SAMPLE_RATE as f64;
        let lang = req.language.filter(|l| !l.is_empty()).or_else(|| self.default_language.clone());
        let t = Instant::now();
        if let (true, Some(preview)) = (req.preview, &self.preview) {
            // Preview: fast but rough, no prompt or hotword support; requests are frequent, so they are not logged
            let lang = lang.unwrap_or_else(|| "auto".into()).to_lowercase();
            let lang = if ["zh", "en", "yue", "ja", "ko"].contains(&lang.as_str()) { lang } else { "auto".into() };
            let text = preview.transcribe(&req.pcm, &lang)?;
            return Ok(Output { text, language: None, audio_s, elapsed_s: t.elapsed().as_secs_f64() });
        }

        let lang = lang.map(|l| {
            let lower = l.to_lowercase();
            LANGUAGES.iter().find(|(k, _)| *k == lower).map(|(_, v)| v.to_string()).unwrap_or(l)
        });
        // Qwen3-ASR takes context biasing via the system prompt: hotwords joined with commas, on a new line after the prompt
        let prompt = req.prompt.filter(|p| !p.is_empty());
        let words = req.hotwords.join(", ");
        let system = match (prompt, words.is_empty()) {
            (Some(p), false) => Some(format!("{p}\n{words}")),
            (Some(p), true) => Some(p),
            (None, false) => Some(words),
            (None, true) => None,
        };
        let out = self.main.transcribe(&req.pcm, lang.as_deref(), system.as_deref())?;
        let elapsed = t.elapsed().as_secs_f64();
        log::info!("transcribed {audio_s:.1}s of audio in {:.0}ms, {} chars", elapsed * 1000.0, out.text.chars().count());
        Ok(Output { text: out.text, language: out.language.or(lang), audio_s, elapsed_s: elapsed })
    }
}
