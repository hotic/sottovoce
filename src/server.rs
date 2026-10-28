//! HTTP server: OpenAI-compatible /v1/audio/transcriptions and /v1/chat/completions (audio input).
//!
//! The two entry points cover the common client styles:
//! - Command-line tools (e.g. curl) and the dictation app upload a multipart file -> /v1/audio/transcriptions
//! - Clients that call Qwen3-ASR the way a vLLM deployment serves it -> /v1/chat/completions, with the audio
//!   in the message content as input_audio (base64) or audio_url (data URI)

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::{ConnectInfo, DefaultBodyLimit, Multipart, Request, State};
use axum::http::{header, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine as _;
use serde_json::{json, Value};

use crate::audio::{decode, DecodeError};
use crate::engine::{self, Engine, Output};
use crate::hotwords::{split, HotwordsFile};

pub struct AppState {
    pub engine: Engine,
    pub token: Option<String>,
    pub hotwords: HotwordsFile,
    pub ffmpeg: PathBuf,
}

type Shared = Arc<AppState>;

pub fn router(state: Shared) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/v1/models", get(models))
        .route("/v1/audio/transcriptions", post(transcriptions))
        .route("/v1/chat/completions", post(chat))
        .layer(middleware::from_fn_with_state(state.clone(), auth))
        // Long voice messages can be tens of MB; axum accepts only 2 MB by default
        .layer(DefaultBodyLimit::max(256 * 1024 * 1024))
        .with_state(state)
}

/// API error; the response body matches FastAPI's HTTPException: {"detail": "..."}
struct ApiError(StatusCode, String);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({ "detail": self.1 }))).into_response()
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(e: anyhow::Error) -> Self {
        log::error!("transcription failed: {e:#}");
        ApiError(StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}"))
    }
}

fn bad_request(msg: impl Into<String>) -> ApiError {
    ApiError(StatusCode::BAD_REQUEST, msg.into())
}

/// Checked only when a token is configured; /health is always open for launchd / monitoring probes.
/// Loopback requests skip the token, so local clients need no configuration; the token only guards requests from
/// other machines
async fn auth(State(st): State<Shared>, ConnectInfo(addr): ConnectInfo<SocketAddr>, req: Request, next: Next) -> Response {
    if let Some(token) = &st.token {
        let local = addr.ip().is_loopback() || addr.ip().to_canonical().is_loopback();
        if !local && req.uri().path() != "/health" {
            let ok = req
                .headers()
                .get(header::AUTHORIZATION)
                .and_then(|v| v.to_str().ok())
                .is_some_and(|v| v == format!("Bearer {token}"));
            if !ok {
                return (StatusCode::UNAUTHORIZED, Json(json!({"error": {"message": "unauthorized"}}))).into_response();
            }
        }
    }
    next.run(req).await
}

async fn health(State(st): State<Shared>) -> Json<Value> {
    // Listening starts only after the models load, so any response means the server is ready
    Json(json!({ "ok": true, "model": st.engine.model_id }))
}

async fn models(State(st): State<Shared>) -> Json<Value> {
    let mut ids = vec![st.engine.model_id.clone()];
    if st.engine.has_preview {
        ids.push("preview".into());
    }
    let data: Vec<Value> = ids.iter().map(|i| json!({"id": i, "object": "model", "owned_by": "sottovoce"})).collect();
    Json(json!({ "object": "list", "data": data }))
}

async fn transcriptions(State(st): State<Shared>, mut form: Multipart) -> Result<Response, ApiError> {
    let (mut file, mut suffix) = (None, String::new());
    let (mut model, mut language, mut prompt, mut hotwords) = (None, None, None, None);
    let mut format = "json".to_string();
    while let Some(field) = form.next_field().await.map_err(|e| bad_request(format!("failed to parse form: {e}")))? {
        let name = field.name().unwrap_or_default().to_string();
        if name == "file" {
            suffix = field
                .file_name()
                .and_then(|f| std::path::Path::new(f).extension())
                .map(|e| format!(".{}", e.to_string_lossy()))
                .unwrap_or_default();
            file = Some(field.bytes().await.map_err(|e| bad_request(format!("failed to read uploaded file: {e}")))?);
            continue;
        }
        let value = field.text().await.map_err(|e| bad_request(format!("failed to parse form: {e}")))?;
        match name.as_str() {
            // Only "preview" selects the preview model; any other value uses the main model
            "model" => model = Some(value),
            "language" => language = Some(value),
            "prompt" => prompt = Some(value),
            "response_format" => format = value,
            // Extension field: hotwords separated by commas or newlines
            "hotwords" => hotwords = Some(value),
            _ => {}
        }
    }
    let file = file.ok_or_else(|| bad_request("missing file field"))?;
    let preview = model.as_deref() == Some("preview");
    // Reject outright when no preview model is loaded: falling back to the main model would let the client's
    // preview polling (every 0.3 s) clog the inference queue. The dictation app stops previewing on error;
    // the final transcript is unaffected
    if preview && !st.engine.has_preview {
        return Err(bad_request("preview model is not loaded"));
    }
    let hotwords = hotwords.as_deref().map(split).unwrap_or_default();
    let out = run(&st, file.to_vec(), suffix, language, prompt, hotwords, preview).await?;
    Ok(match format.as_str() {
        "text" => out.text.into_response(),
        "verbose_json" => Json(json!({
            "text": out.text,
            "language": out.language,
            "duration": out.audio_s,
            "elapsed": (out.elapsed_s * 1000.0).round() / 1000.0,
        }))
        .into_response(),
        _ => Json(json!({ "text": out.text })).into_response(),
    })
}

async fn chat(State(st): State<Shared>, Json(body): Json<Value>) -> Result<Response, ApiError> {
    let messages = body.get("messages").and_then(Value::as_array).cloned().unwrap_or_default();
    let (audio, fmt, context) = extract_chat_audio(&messages);
    let audio = audio.ok_or_else(|| bad_request("no audio in messages (expected input_audio or an audio_url data URI)"))?;
    let language = body.get("language").and_then(Value::as_str).map(String::from);
    let suffix = fmt.map(|f| format!(".{f}")).unwrap_or_default();
    let out = run(&st, audio, suffix, language, context, Vec::new(), false).await?;

    let id = format!("chatcmpl-{}", &uuid::Uuid::new_v4().simple().to_string()[..24]);
    let created = chrono::Utc::now().timestamp();
    let model = body.get("model").and_then(Value::as_str).filter(|m| !m.is_empty()).unwrap_or(&st.engine.model_id).to_string();
    if body.get("stream").and_then(Value::as_bool).unwrap_or(false) {
        // Streaming requests also get everything at once: one content chunk plus the final chunk
        let chunk = |delta: Value, finish: Value| {
            let c = json!({"id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                           "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]});
            format!("data: {c}\n\n")
        };
        let sse = chunk(json!({"role": "assistant", "content": out.text}), Value::Null)
            + &chunk(json!({}), json!("stop"))
            + "data: [DONE]\n\n";
        return Ok(([(header::CONTENT_TYPE, "text/event-stream")], Body::from(sse)).into_response());
    }
    Ok(Json(json!({
        "id": id, "object": "chat.completion", "created": created, "model": model,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": out.text}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }))
    .into_response())
}

async fn run(
    st: &Shared,
    data: Vec<u8>,
    suffix: String,
    language: Option<String>,
    prompt: Option<String>,
    hotwords: Vec<String>,
    preview: bool,
) -> Result<Output, ApiError> {
    let ffmpeg = st.ffmpeg.clone();
    let pcm = tokio::task::spawn_blocking(move || decode(&data, &suffix, &ffmpeg))
        .await
        .map_err(|e| ApiError(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|DecodeError(msg)| bad_request(msg))?;
    // Global hotwords apply only to final transcripts; the preview model does not support hotwords
    let hotwords = if preview { hotwords } else { st.hotwords.merge(hotwords) };
    let mut out = st.engine.transcribe(engine::Request { pcm, language, prompt, hotwords, preview }).await?;
    out.text = st.hotwords.fix(out.text);
    Ok(out)
}

/// Take the last audio part; text from system messages is joined into the context prompt (Qwen3-ASR biasing)
fn extract_chat_audio(messages: &[Value]) -> (Option<Vec<u8>>, Option<String>, Option<String>) {
    let b64 = base64::engine::general_purpose::STANDARD;
    let (mut audio, mut fmt) = (None, None);
    let mut context: Vec<String> = Vec::new();
    for msg in messages {
        let system = msg.get("role").and_then(Value::as_str) == Some("system");
        match msg.get("content") {
            Some(Value::String(s)) => {
                if system && !s.trim().is_empty() {
                    context.push(s.trim().to_string());
                }
            }
            Some(Value::Array(parts)) => {
                for part in parts {
                    match part.get("type").and_then(Value::as_str) {
                        Some("input_audio") => {
                            let ia = part.get("input_audio");
                            let data = ia.and_then(|v| v.get("data")).and_then(Value::as_str).unwrap_or("");
                            audio = Some(b64.decode(data).unwrap_or_default());
                            fmt = ia.and_then(|v| v.get("format")).and_then(Value::as_str).map(String::from);
                        }
                        Some("audio_url") => {
                            let url = part.pointer("/audio_url/url").and_then(Value::as_str).unwrap_or("");
                            if let Some((header, payload)) = url.strip_prefix("data:").and_then(|u| u.split_once(',')) {
                                audio = Some(b64.decode(payload).unwrap_or_default());
                                let mime = header.split(';').next().unwrap_or("");
                                fmt = mime.rsplit('/').next().filter(|f| !f.is_empty()).map(String::from);
                            }
                        }
                        Some("text") if system => {
                            if let Some(t) = part.get("text").and_then(Value::as_str).filter(|t| !t.trim().is_empty()) {
                                context.push(t.trim().to_string());
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    let context = (!context.is_empty()).then(|| context.join("\n"));
    (audio, fmt, context)
}
