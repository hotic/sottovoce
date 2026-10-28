//! CLI entry point: load the models, then listen for HTTP. Every flag can also be set via a SOTTOVOCE_* environment
//! variable (used by the LaunchAgent).

use std::io::Write;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;

use sottovoce::engine::Engine;
use sottovoce::hotwords::HotwordsFile;
use sottovoce::server::{router, AppState};

#[derive(Parser)]
#[command(name = "sottovoce", version, about = "Sottovoce: always-on local speech recognition server")]
struct Args {
    #[arg(long, env = "SOTTOVOCE_HOST", default_value = "127.0.0.1")]
    host: String,
    #[arg(long, env = "SOTTOVOCE_PORT", default_value_t = 8008)]
    port: u16,
    #[arg(long, env = "SOTTOVOCE_MODEL", default_value = "mlx-community/Qwen3-ASR-1.7B-8bit")]
    model: String,
    /// Fast model for live dictation previews; pass an empty string to skip loading it
    #[arg(long, env = "SOTTOVOCE_PREVIEW_MODEL", default_value = "mlx-community/SenseVoiceSmall")]
    preview_model: String,
    /// Default language, e.g. zh; auto-detected when unset
    #[arg(long, env = "SOTTOVOCE_LANGUAGE")]
    language: Option<String>,
    /// Global hotwords file, one per line, changes apply immediately; pass an empty string to disable
    #[arg(long, env = "SOTTOVOCE_HOTWORDS", default_value = "~/.config/sottovoce/hotwords.txt")]
    hotwords: String,
    #[arg(long, env = "SOTTOVOCE_FFMPEG", default_value = "/opt/homebrew/bin/ffmpeg")]
    ffmpeg: PathBuf,
    /// Set by the dictation app: exit when the parent process goes away, even if it crashed, so no orphaned server
    /// keeps the port and the GPU memory
    #[arg(long, hide = true)]
    exit_with_parent: bool,
}

fn expand_home(p: &str) -> PathBuf {
    match (p.strip_prefix("~/"), std::env::var_os("HOME")) {
        (Some(rest), Some(home)) => PathBuf::from(home).join(rest),
        _ => PathBuf::from(p),
    }
}

fn main() -> Result<()> {
    // Log format: 2026-10-15 06:44:22,646 INFO message
    env_logger::Builder::new()
        .filter_level(log::LevelFilter::Info)
        .format(|buf, r| {
            let now = chrono::Local::now();
            writeln!(buf, "{},{:03} {} {}", now.format("%Y-%m-%d %H:%M:%S"), now.timestamp_subsec_millis(), r.level(), r.args())
        })
        .init();
    let args = Args::parse();
    let token = std::env::var("SOTTOVOCE_TOKEN").ok().filter(|t| !t.is_empty());
    let loopback = ["127.0.0.1", "localhost", "::1"].contains(&args.host.as_str());
    if !loopback && token.is_none() {
        log::warn!("listening on {} without SOTTOVOCE_TOKEN; anyone on the network can call the API", args.host);
    }

    if args.exit_with_parent {
        watch_parent();
    }
    use_bundled_metallib()?;

    let preview = Some(args.preview_model.as_str()).filter(|m| !m.is_empty());
    let language = args.language.filter(|l| !l.is_empty());
    let engine = Engine::start(&args.model, preview, language)?;
    let hotwords = HotwordsFile::new(Some(args.hotwords.as_str()).filter(|p| !p.is_empty()).map(expand_home));
    let state = Arc::new(AppState { engine, token, hotwords, ffmpeg: args.ffmpeg });

    let addr: SocketAddr = format!("{}:{}", if args.host == "localhost" { "127.0.0.1" } else { &args.host }, args.port)
        .parse()
        .with_context(|| format!("invalid listen address: {}:{}", args.host, args.port))?;
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
    rt.block_on(async move {
        let listener = tokio::net::TcpListener::bind(addr).await.with_context(|| format!("failed to listen on {addr}"))?;
        log::info!("listening on http://{addr}");
        let app = router(state).into_make_service_with_connect_info::<SocketAddr>();
        axum::serve(listener, app).with_graceful_shutdown(shutdown()).await?;
        Ok(())
    })
}

/// Inside Sottovoce.app the server is Contents/MacOS/sottovoce-server and MLX's Metal kernels are
/// Contents/Resources/mlx.metallib. The kernel path compiled into the binary only exists on the build machine, so point
/// MLX at the bundled copy before the models load. A plain `cargo build` binary has no such file and keeps the default
fn use_bundled_metallib() -> Result<()> {
    let exe = std::env::current_exe().context("failed to locate the server executable")?;
    let Some(lib) = exe.parent().and_then(|d| d.parent()).map(|c| c.join("Resources/mlx.metallib")) else {
        return Ok(());
    };
    if lib.is_file() {
        mlx_rs::metal::set_metallib_path(lib.to_string_lossy()).map_err(|e| anyhow::anyhow!("{e}"))?;
        log::info!("using the bundled Metal kernels: {}", lib.display());
    }
    Ok(())
}

/// The parent becomes launchd (pid 1) once it exits; checking once a second is plenty for freeing the port
fn watch_parent() {
    let parent = std::os::unix::process::parent_id();
    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_secs(1));
        if std::os::unix::process::parent_id() != parent {
            log::info!("parent process {parent} exited, stopping");
            std::process::exit(0);
        }
    });
}

/// `launchctl kickstart -k` sends SIGTERM, a terminal sends Ctrl-C; on either, stop accepting new requests and
/// exit once in-flight requests finish
async fn shutdown() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut term = signal(SignalKind::terminate()).expect("failed to register SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = term.recv() => {}
    }
    log::info!("received shutdown signal, stopping");
}
