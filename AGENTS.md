# Sottovoce development notes

An always-on local speech recognition server. Qwen3-ASR 1.7B runs on MLX (Apple Silicon), is loaded once, and is served through an OpenAI-compatible HTTP API to local and LAN clients. Written in Rust and built into a single binary. `app/` holds the macOS dictation app, which carries that binary inside and runs it; the app's DMG is what releases ship. Usage and the API are in `README.md`; this file only records facts needed for development and operations.

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
- `app/Sources/Sottovoce/LocalServer.swift`: runs the bundled server in "This Mac" mode; `Models.swift`: the model list and the downloader
- `app/package.sh`: the Developer ID signed, notarized DMG; `.github/workflows/release.yml` runs it for a published GitHub Release
- `app/AppIcon.icon`: the app icon as an Icon Composer document (gray gradient fill, one glass layer with the wave). `app/build.sh` compiles it with `actool`, so macOS 26 renders it as Liquid Glass and earlier systems get a flat `.icns`. Edit it in Icon Composer (inside Xcode.app); `media/icon.png` is the README copy of the rendered icon and must be re-exported when the icon changes
- `media/readme/`: the README demo GIF in English and Chinese (talk while reading an issue, click into an agent chat box, release). They were screen-recorded from a throwaway harness that drives a copy of `HUD.swift` with scripted states and TTS audio levels; the harness is not in the repo, so re-record them when the HUD changes visibly

## Commands

- `cargo build --release`: produces `target/release/sottovoce`. The first build compiles MLX from source (about 5 minutes) and needs Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`)
- `target/release/sottovoce [--host --port --model --preview-model --language --hotwords --ffmpeg]`: run in the foreground. Equivalent environment variables: `SOTTOVOCE_HOST` / `PORT` / `MODEL` / `PREVIEW_MODEL` / `LANGUAGE` / `HOTWORDS` / `FFMPEG` / `TOKEN`. When testing next to a running service, use another port (e.g. `--port 8009`)
- `scripts/smoke.py [url]`: generates audio with the system TTS, calls every endpoint, and checks that bad audio returns 400; pass `SOTTOVOCE_TOKEN` when the server requires a token
- `launchctl kickstart -k gui/$(id -u)/sh.asgard.sottovoce.server`: restart the LaunchAgent after `cargo build --release`
- `app/build.sh [--install]`: builds the server into `target/app` (its own target directory, see below), then the app, and packages both into `app/build/Sottovoce.app`
- `app/package.sh`: `app/build/Sottovoce-<version>.dmg` for other Macs; needs a Developer ID identity, and notarization credentials to be of any use (see "Releasing")
- Log: `/tmp/sottovoce.log` when run from the LaunchAgent, `~/Library/Logs/Sottovoce/server.log` when run by the app (one line per transcription: audio length, elapsed time, character count)

## Definition of done

- `cargo build --release` with no errors and no warnings
- After restarting the service, `scripts/smoke.py` reports ok for everything
- When `app/` changed, `app/build.sh` compiles; changes to recording, hotkeys, or pasting need a real install and test (`app/build.sh --install`)
- When a user-visible app string changed, update `app/Resources/zh-Hans.lproj/Localizable.strings`
- When the plist changed, run `plutil -lint` on it and reinstall (`launchctl bootout`, then `bootstrap`)
- When `app/package.sh` or the release workflow changed, run `actionlint` and `app/package.sh` without notarization credentials (it still signs and builds the DMG); the notarization path only runs in CI
- There are no unit tests. Add tests only for problems that actually happened, never tests that restate the implementation

## Constraints and pitfalls

- MLX streams are bound to threads: models must be loaded on the same thread that runs inference. The `Engine` thread doubles as the request queue; do not make it multi-threaded or call the models from another thread
- Numerical parity with the port: on the same audio, the Rust server produces exactly the same tokens as mlx-audio 0.5.9 (verified on 10 TTS clips × with/without hotwords, final and preview, including a 30-second sentence). The key is copying Python's operators and precision: linear layers use `addmm`, norms use the `fast` ops, subtract `logsumexp` before picking a token; in the Whisper features the FFT output is rounded to complex64 first and the final clipping and scaling happen in f32 (numpy does this, and one ulp of difference changes borderline audio)
- MLX's Metal kernel library: mlx-sys puts `mlx.metallib` in `~/.mlx/lib/<mlx-c source hash>/` at build time and compiles that path into the binary; deleting the directory requires another `cargo build`. That path only exists on the build machine, so in the app the server finds `Contents/Resources/mlx.metallib` from its own location and hands it to MLX (`use_bundled_metallib` in `main.rs`) before any model loads
- The app's server is built by `app/build.sh` in `target/app` with `MACOSX_DEPLOYMENT_TARGET=14.0` and `MLX_RS_METAL_PATH=target/app/metal`: unset, MLX compiles its kernels for the build machine's macOS (Metal 4 on macOS 26+), which older systems can't load. The 14.0 build uses Metal 3.1 without the NAX kernels (M5 neural accelerators, which need a 26.2 target). On 5 TTS clips it produced exactly the same final and preview text as the host build, at the same latency (October 2026). Changing either variable in `target/release` would rebuild MLX, which is why it is a separate target directory
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

- Signing: `app/build.sh` signs with a self-signed certificate in a dedicated keychain, `~/Library/Keychains/sottovoce-signing.keychain-db` (empty password), unless `SOTTOVOCE_SIGN_IDENTITY` names a Developer ID identity. The designated requirement is identifier + certificate fingerprint, so rebuilding keeps the Accessibility / Microphone grants. Deleting that keychain, changing the bundle id, or switching between a source build and a release build (different certificates) requires granting again. If System Settings shows the switch on but the app says it is not authorized, the grant is bound to an old signature: clear it with `tccutil reset Accessibility sh.asgard.sottovoce` (Microphone likewise) and grant again
- Both kinds of build use the hardened runtime (notarization requires it), so the app declares `com.apple.security.device.audio-input` in `app/Sottovoce.entitlements`; without it recording fails silently. The server is signed first (identifier `sh.asgard.sottovoce.server`, no entitlements) because the app's signature seals it
- Built-in server (`LocalServer`): in "This Mac" mode the app starts `Contents/MacOS/sottovoce-server` on port 8008 with `--exit-with-parent`, checks `/health` every 2 s, restarts it when the model, live preview, or sharing settings change, and gives up after 3 exits within a minute (showing the log's last error). If something already answers on 8008 when no own server runs (a LaunchAgent, a CLI run), the app uses it and starts nothing, so the LaunchAgent setup keeps working. The executable is `sottovoce-server`, not `sottovoce`, because `Contents/MacOS/Sottovoce` is the app and APFS is usually case-insensitive
- `--exit-with-parent` polls the parent pid once a second: an app killed with SIGKILL, or by `pkill` during `app/build.sh --install` (NSApplication doesn't run `applicationWillTerminate` on SIGTERM), would otherwise leave the server holding the port and GPU memory
- The preview model is loaded when live preview is on or sharing is on (other Macs may want previews). The sharing token is generated on first use and only passed to the server while sharing is on; with it in the config unconditionally, a token change restarted an unshared server
- Model downloads (`ModelDownloader`): the file list and sizes come from `/api/models/<repo>/revision/main?blobs=true`; files go straight into `snapshots/<commit>/` (plain files, not blob symlinks; huggingface_hub accepts that) and `refs/main` is written last, so the server never sees a partial snapshot. Each file downloads to `<name>.incomplete` and resumes with an HTTP Range request across retries and app restarts; LFS files are checked against the published SHA-256. `README.md` and `.gitattributes` are skipped. When huggingface.co is unreachable, hf-mirror.com (same URL layout) is used. hf-mirror answers non-Chinese IPs with a 308 back to huggingface.co, so its own behavior can only be seen from China
- The sharing section lists IPv4 addresses from `getifaddrs`, minus loopback, 169.254/16, and 198.18/15 (the fake-IP range of Clash / Surge TUN interfaces)
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
- Not implemented yet: request priority (dictation ahead of batch jobs), a Windows client, automatic app updates

## Releasing

1. Set the version in `Cargo.toml`; `app/build.sh` copies it into the app's `Info.plist`, so `app/Info.plist`'s own version is never shipped. Commit and push.
2. Publish a GitHub Release tagged `v<version>`. `.github/workflows/release.yml` builds on a `macos-26` runner (most of the time goes to compiling MLX and waiting for notarization), checks the tag against `Cargo.toml`, and attaches `Sottovoce-<version>.dmg` and `Sottovoce.sha256`. A retry keeps assets already attached; a changed app needs a new version.
3. A manual run (`workflow_dispatch`, publish unchecked) builds the same DMG as a workflow artifact without touching a Release.

Repository secrets, the same values the acpira repository uses (it signs with the same Developer ID):

| Secret | Source |
| --- | --- |
| `APPLE_CERTIFICATE` | The Developer ID Application certificate with its private key, exported from Keychain Access as `.p12`, base64-encoded |
| `APPLE_CERTIFICATE_PASSWORD` | The `.p12` export password |
| `APPLE_API_KEY` / `APPLE_API_ISSUER` | Key ID and Issuer ID of an App Store Connect API key (Users and Access › Integrations) for notarization |
| `APPLE_API_KEY_P8` | The contents of that key's `AuthKey_<id>.p8` |

Without them the workflow stops at its first step: an unnotarized DMG is exactly what Gatekeeper calls damaged or unverified. To package locally, `app/package.sh` takes the same API key through `APPLE_API_KEY` / `APPLE_API_ISSUER` / `APPLE_API_KEY_PATH`, or a notarytool keychain profile through `SOTTOVOCE_NOTARY_PROFILE`; without either it builds a signed, unnotarized DMG for checking the packaging only.
