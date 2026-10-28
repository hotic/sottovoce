//! Global hotwords file. Text after # is a comment. Two kinds of lines:
//!
//! - Plain line: hotwords, one per line (commas also work), passed to the model as biasing for final transcripts
//! - Line containing `=>`: a replacement rule `regex => replacement`, case-insensitive, applied to the recognized
//!   text (both final and preview). Hotwords only help the model hear the right sounds; the spelling still varies
//!   (Gen1 / Gen 1 / -gen1), and this layer normalizes it
//!
//! Cached by modification time: edits take effect on the next request without a restart. A missing file counts as empty.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::SystemTime;

use fancy_regex::{NoExpand, Regex};

#[derive(Default)]
struct State {
    mtime: Option<Option<SystemTime>>,
    words: Vec<String>,
    rules: Vec<(Regex, String)>,
}

pub struct HotwordsFile {
    path: Option<PathBuf>,
    state: Mutex<State>,
}

/// Hotword list separated by commas or newlines (also used to parse the request's hotwords field)
pub fn split(s: &str) -> Vec<String> {
    s.split([',', '\n']).map(str::trim).filter(|w| !w.is_empty()).map(String::from).collect()
}

impl HotwordsFile {
    pub fn new(path: Option<PathBuf>) -> Self {
        Self { path, state: Mutex::default() }
    }

    fn with_state<T>(&self, f: impl FnOnce(&State) -> T) -> T {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(path) = &self.path {
            let mtime = std::fs::metadata(path).and_then(|m| m.modified()).ok();
            if st.mtime != Some(mtime) {
                let text = mtime.and_then(|_| std::fs::read_to_string(path).ok()).unwrap_or_default();
                let (mut words, mut rules) = (Vec::new(), Vec::new());
                for line in text.lines() {
                    let line = line.split('#').next().unwrap_or("").trim();
                    if let Some((pattern, repl)) = line.split_once("=>") {
                        let pattern = pattern.trim();
                        match Regex::new(&format!("(?i){pattern}")) {
                            Ok(re) => rules.push((re, repl.trim().to_string())),
                            Err(e) => log::warn!("skipping invalid replacement rule in hotwords file: {pattern} ({e})"),
                        }
                    } else if !line.is_empty() {
                        words.extend(split(line));
                    }
                }
                log::info!("loaded {} hotwords and {} replacement rules: {}", words.len(), rules.len(), path.display());
                *st = State { mtime: Some(mtime), words, rules };
            }
        }
        f(&st)
    }

    /// Request hotwords first, then global ones, deduplicated case-insensitively
    pub fn merge(&self, request: Vec<String>) -> Vec<String> {
        let global = self.with_state(|st| st.words.clone());
        let mut seen = std::collections::HashSet::new();
        request.into_iter().chain(global).filter(|w| seen.insert(w.to_lowercase())).collect()
    }

    /// Normalize spelling with the replacement rules; replacements are literal, $1-style references are not expanded
    pub fn fix(&self, text: String) -> String {
        self.with_state(|st| {
            st.rules.iter().fold(text, |acc, (re, repl)| re.replace_all(&acc, NoExpand(repl)).into_owned())
        })
    }
}
