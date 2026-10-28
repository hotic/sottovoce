# Sottovoce development notes

An always-on local speech recognition server. Qwen3-ASR 1.7B runs on MLX (Apple Silicon), is loaded once, and is served through an OpenAI-compatible HTTP API to local and LAN clients. Written in Rust and built into a single binary. `app/` holds the companion macOS dictation app. Usage and the API are in `README.md`; this file only records facts needed for development and operations.

If `AGENTS.local.md` exists (it is gitignored), read it too: it describes the machine-specific deployment and clients.

## Layout

- `src/main.rs`: CLI entry point, arguments, logging, loads the models before listening, graceful shutdown on SIGTERM
- `src/server.rs`: axum routes, both transcription endpoints, optional bearer token, token-free `/health`; error responses keep FastAPI's `{"detail": ...}` shape
- `src/engine.rs`: the inference thread; the main model and the preview model (SenseVoice) are both loaded and run on one dedicated thread, with a channel acting as the request queue
- `src/qwen3_asr.rs`: Qwen3-ASR audio encoder, text decoder (8-bit quantized), Qwen2 BPE tokenizer, greedy decoding
- `src/sensevoice.rs`: SenseVoice SANM encoder and CTC decoding; the sentencepiece vocabulary is parsed straight from the protobuf
- `src/features.rs`: Whisper log-mel and Kaldi fbank, computed on the CPU
- `src/nn.rs`: weight maps, plain and quantized linear / embedding layers, Hugging Face cache lookup
- `src/hotwords.rs`: the global hotwords file and replacement rules
- `src/audio.rs`: decodes any format to 16 kHz mono f32 through ffmpeg; a WAV that is already 16 kHz mono 16-bit is read directly, saving one ffmpeg process (about 26 ms)
- `deploy/sh.asgard.sottovoce.server.plist`: per-user LaunchAgent template
- `scripts/smoke.py`: smoke test
- `app/`: macOS menu bar dictation app (Swift Package, packaged by `app/build.sh`), English UI with a zh-Hans localization in `app/Resources/`
- `app/AppIcon.icon`: the app icon as an Icon Composer document (gray gradient fill, one glass layer with the wave). `app/build.sh` compiles it with `actool`, so macOS 26 renders it as Liquid Glass and earlier systems get a flat `.icns`. Edit it in Icon Composer (inside Xcode.app); `media/icon.png` is the README copy of the rendered icon and must be re-exported when the icon changes
- `media/readme/`: the README demo GIF in English and Chinese (talk while reading an issue, click into an agent chat box, release). They were screen-recorded from a throwaway harness that drives a copy of `HUD.swift` with scripted states and TTS audio levels; the harness is not in the repo, so re-record them when the HUD changes visibly

## Commands

- `cargo build --release`: produces `target/release/sottovoce`. The first build compiles MLX from source (about 5 minutes) and needs Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`)
- `target/release/sottovoce [--host --port --model --preview-model --language --hotwords --ffmpeg]`: run in the foreground. Equivalent environment variables: `SOTTOVOCE_HOST` / `PORT` / `MODEL` / `PREVIEW_MODEL` / `LANGUAGE` / `HOTWORDS` / `FFMPEG` / `TOKEN`. When testing next to a running service, use another port (e.g. `--port 8009`)
- `scripts/smoke.py [url]`: generates audio with the system TTS, calls every endpoint, and checks that bad audio returns 400; pass `SOTTOVOCE_TOKEN` when the server requires a token
- `launchctl kickstart -k gui/$(id -u)/sh.asgard.sottovoce.server`: restart the LaunchAgent after `cargo build --release`
- Log: `/tmp/sottovoce.log` when run from the LaunchAgent (one line per transcription: audio length, elapsed time, character count)

## Definition of done

- `cargo build --release` with no errors and no warnings
- After restarting the service, `scripts/smoke.py` reports ok for everything
- When `app/` changed, `app/build.sh` compiles; changes to recording, hotkeys, or pasting need a real install and test (`app/build.sh --install`)
- When a user-visible app string changed, update `app/Resources/zh-Hans.lproj/Localizable.strings`
- When the plist changed, run `plutil -lint` on it and reinstall (`launchctl bootout`, then `bootstrap`)
- There are no unit tests. Add tests only for problems that actually happened, never tests that restate the implementation

## Constraints and pitfalls

- MLX streams are bound to threads: models must be loaded on the same thread that runs inference. The `Engine` thread doubles as the request queue; do not make it multi-threaded or call the models from another thread
- Numerical parity with the port: on the same audio, the Rust server produces exactly the same tokens as mlx-audio 0.5.9 (verified on 10 TTS clips × with/without hotwords, final and preview, including a 30-second sentence). The key is copying Python's operators and precision: linear layers use `addmm`, norms use the `fast` ops, subtract `logsumexp` before picking a token; in the Whisper features the FFT output is rounded to complex64 first and the final clipping and scaling happen in f32 (numpy does this, and one ulp of difference changes borderline audio)
- MLX's Metal kernel library: mlx-sys puts `mlx.metallib` in `~/.mlx/lib/<mlx-c source hash>/` at build time and compiles that path into the binary; deleting the directory requires another `cargo build`
- Memory has to be measured with `footprint <pid>` or Activity Monitor: MLX weights live in GPU buffers (IOAccelerator), so `ps` RSS is far too low (0.6B shows 0.06 GB, actually 1.1 GB)
- Without the preview model loaded, `model=preview` returns 400 instead of falling back to the main model: the client polls previews every 0.3 s and would clog the queue for final results
- Tokenizer: the model directory only has `vocab.json` + `merges.txt`; it is assembled to match the Qwen2TokenizerFast configuration (NFC, regex pre-tokenization, ByteLevel), added tokens are inserted in id order and their ids are checked
- Do not assume a 44-byte WAV header: ffmpeg writes a LIST chunk between fmt and data, so scan chunk by chunk
- Decoding writes a temporary file before handing it to ffmpeg: CAF / MP4 indexes may sit at the end of the file, and a pipe cannot seek back
- Qwen3-ASR context biasing goes through `system_prompt`; mlx-audio concatenates `hotwords` into the same field. Hotwords work in practice and are strong: a hotword pulls similar-sounding words onto itself, even when the similar word was what was said
- Names with hyphens or digits are unstable through hotwords alone: write the hotword as it is spoken (`Gen 1`), then normalize the spelling with a `=>` replacement rule
- The hotwords file is reloaded by modification time; each load logs the number of hotwords and replacement rules
- zsh does not word-split unquoted variables: in curl tests, `${p:+-F "prompt=$p"}` becomes one malformed field and the server never sees the prompt, which silently invalidates comparisons. Pass arguments through an array or `"$@"`
- mlx-audio 0.5.9 pitfalls from model selection (relevant if it is used as a reference again): FireRedASR2's fbank only accepts `mx.array`; Fun-ASR-Nano 8-bit fails to load with an adaptor shape mismatch and the fp16 version outputs garbage
- Measure before switching models: the October 2026 selection data is in `README.md` (60 WenetSpeech utterances per set; the evaluation script is not in the repo)

## Dictation app

- Signing: `app/build.sh` signs with a self-signed certificate in a dedicated keychain, `~/Library/Keychains/sottovoce-signing.keychain-db` (empty password). The designated requirement is identifier + certificate fingerprint, so rebuilding keeps the Accessibility / Microphone grants. Deleting that keychain or changing the bundle id requires granting again. If System Settings shows the switch on but the app says it is not authorized, the grant is bound to an old signature: clear it with `tccutil reset Accessibility sh.asgard.sottovoce` (Microphone likewise) and grant again
- The app is LSUIElement and has no main menu, so ⌘V and friends have nowhere to go: `setupEditMenu` in `main.swift` installs an invisible Edit menu; without it, the settings window's text fields cannot paste
- Remote mode uses plain `http://`, which ATS blocks with -1022 (`127.0.0.1` is exempt): `app/Info.plist` sets `NSAllowsArbitraryLoads` because the address is user-entered and cannot be allowlisted
- Inline preview (`InlineComposer.swift`): writes `AXSelectedText` at the caret, remembers position and length, selects and replaces on each update, and reads back with `AXStringForRange` after every write. On macOS 27, `AXFocusedUIElement` from `AXUIElementCreateSystemWide()` returns -25204, so it must be read from the frontmost app's element. WeChat, Chrome, and VS Code do not expose the focused element (-25212); setting `AXManualAccessibility` on them may help, and when it doesn't, no preview is written and the final text is pasted. Tested in TextEdit and the Safari address bar (preview, replace, cancel, caret in the middle); Chrome and Electron untested
- The "not a text field" check is deliberately conservative: only clearly non-text controls (lists, buttons, tables, the Finder desktop as `AXGroup` + `AXDesktop`) enter the "click a text field" wait; anything uncertain is pasted directly
- When automating inline-write tests, confirm the target app is frontmost before writing; the system often refuses background activation and the text would land in the window in use
- Live preview is client polling (`model=preview`, recent 20 s of audio every 0.3 s, one request in flight), not WebSocket streaming; previews are frequent, so the server does not log them individually
- SenseVoice outputs things like "Yeah." or "The." for silence, noise, or key clicks: the app waits for about 0.2 s of audio above -30 dB before previewing and drops previews that are a single English word. Qwen3-ASR returns an empty string for silence, so final results are unaffected

## Conventions

- Code comments, documentation, and commit messages are in English; commits follow Conventional Commits
- Write commits and docs impersonally; when a person must be named, use their role
- There is one model instance; the API's `model` field exists for compatibility and does not route (except `preview`)
- Not implemented yet: request priority (dictation ahead of batch jobs), a Windows client
