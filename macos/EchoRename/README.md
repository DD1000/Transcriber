# ClipName for Mac

ClipName proposes descriptive video filenames from local speech transcription and visual scene analysis. Review and edit suggestions before pressing Rename. Duplicate names get numbered, and Undo restores the last completed rename batch.

## Scene naming

- **Speech + scenes** transcribes first, then uses sampled frames for short, empty, or unhelpful speech. Videos without an audio track also use scenes.
- **Scenes only** skips transcription for scenery, music videos, or clips whose speech doesn't describe their contents.
- Every visual suggestion is marked **Based on video scenes**, with an expandable scene description. Unreadable or unclear videos keep their names and show an explanation.

Four small frames are sampled across each video (one for clips shorter than a second). Scene descriptions can miss brief events or make mistakes; they are editable suggestions. Stop preserves completed suggestions. Stopping during speech waits for the current audio operation; scene and naming workers are terminated promptly.

## Filename languages

Choose **Filename language** before analyzing: **Automatic · no translation**, **English**, **Español · Latin America**, or **简体中文 · Mainland China**. Automatic preserves the original speech language with the existing fast naming rules; automatic scene names use English. Whisper explicitly detects the spoken language and transcribes it instead of defaulting to English. The expandable original transcript is never replaced with the localized name.

After analysis, switch language and click **Update names** to regenerate the selected suggestions from that session’s original transcript or scene description. It does not transcribe the audio again and does not change any files. Review or edit suggestions, then click **Rename** to apply them. Existing duplicate numbering and Undo still apply. Analysis is kept only for the current session; closing the app or scanning again clears it.

Localized names use the same free, offline Qwen model as scene analysis, including a text-only path for transcripts. No additional model or paid service is needed if scene setup is already installed. Spanish uses neutral Latin American vocabulary, accents, and complete phrases; Chinese uses Simplified characters and everyday Mainland wording. Prompts favor natural meaning over literal translation and forbid invented cultural details or forced slang. A bounded editing pass improves Spanish grammar and retries Chinese titles containing untranslated English. This is AI-assisted wording, not a native-speaker quality guarantee. Chinese titles that still contain English letters are rejected, which can also reject foreign brand names; retry or edit an automatic suggestion instead.

Translated titles preserve spaces, accents and Chinese characters. Filename separators, control characters, duplicate extensions and excessive byte lengths are handled before renaming. Unclear speech falls back to scenes; a failed localization keeps the prior filename/suggestion and cannot be applied until a new suggestion succeeds. Long transcripts use bounded beginning, middle and ending excerpts, so brief topics can be missed. This feature is shared by the native Mac builds; it does not change the older EchoScribe web app or establish compatibility on additional Mac hardware.

## Local setup

Requires an Apple Silicon Mac, macOS 14+, Swift 6, and [uv](https://docs.astral.sh/uv/getting-started/installation/). An M4 with 16 GB RAM is supported by the tested setup.

```sh
bash scripts/setup-vision.sh
bash scripts/install-app.sh
open "$HOME/Applications/ClipName.app"
```

Scene setup installs a private Python 3.12 runtime and downloads about 3.1 GB of model files into `~/Library/Application Support/ClipName/Vision`. No paid API, model account, or server is required. After setup the scene worker explicitly uses offline mode. Audio uses the existing WhisperKit Large v3 Turbo model and may need its own initial download. Speech models are unloaded before vision starts; each scene worker exits after one video to free memory. The installer keeps the previous app in `~/Library/Application Support/ClipName/Backups`. Existing rename history remains in the legacy `EchoRename` support folder.

The vision model is [Qwen3-VL-4B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit), pinned to revision `2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b`, with an Apache-2.0 license. It runs through [MLX-VLM](https://github.com/Blaizzy/mlx-vlm) 0.7.0. Model code downloaded from the model repository is not executed (`trust_remote_code=False`). Model weights are not included in the app or Git repository.

The directory and Swift module still use the legacy name `EchoRename`; the app product and all visible labels are ClipName.

## Checks

```sh
swift build --product ClipName
python3 -m unittest discover -s Tests -p 'test_*.py'
swiftc -parse-as-library Sources/EchoRename/VideoFrameSampler.swift Sources/EchoRename/SpeechNamingPolicy.swift Sources/EchoRename/TitleGenerator.swift scripts/smoke.swift -o /tmp/clipname-smoke
/tmp/clipname-smoke
```

The native smoke harness creates its own tiny test videos. It never renames user files.

## Private test-video suite and model reports

Use a repeatable local set of your own videos without publishing them:

```sh
python3 scripts/benchmark.py import '/absolute/path/to/test videos'
swift build --product ClipName --jobs 2 --force-resolved-versions
python3 scripts/benchmark.py run
```

Import makes byte-for-byte copies under `.private-tests/user-videos/videos`, with a
SHA-256 manifest. It never moves or renames the source videos. Existing suites are
not overwritten; use `--suite another-name` on both commands to create another set.
The entire `.private-tests` directory is ignored by Git, including media, manifests,
transcripts, raw process logs and results. Do not force-add it or upload it as a CI
artifact. Personal recordings and their contents need explicit permission before
sharing. CI's normal tests use only synthetic bytes/videos, not this private suite.

Each `run` creates a new private `runs/<timestamp-id>/` folder with `report.md`,
`results.json`, and each model's individual result and log. It evaluates the app's
current Whisper speech model and Qwen scene model independently on **every** clip,
even when automatic mode would use speech alone. Reports include transcripts,
parsed scene descriptions, suggested filenames, automatic-mode choice, model IDs,
checkout's declared vision revision, dependency lock, source and executable hashes, Mac chip/macOS/RAM,
duration and errors. Suggestions are before duplicate numbering; no rename operation
is executed. There are no accuracy scores until reference transcripts/scene labels
are supplied and reviewed. The optional manifest expectation fields are reserved
for that review; the runner does not grade them automatically.

Models run one at a time in isolated native processes. Timings include startup,
media extraction, model loading and inference, so they are not warm-app throughput
measurements. Each process has a ten-minute limit (`--timeout` changes it); timeouts
and crashes are recorded and testing continues. Each result is saved as it completes;
Ctrl-C stops the active model group and retains the partial report. A fresh app build
is required after source changes. Headless evaluation is explicitly selected with
`ClipName --benchmark`; normal app launches still open the standard Mac interface.

The test runner itself doesn't upload media. WhisperKit can download model metadata
or missing weights; scene inference uses the already-installed offline vision setup.
Use `--engines speech` or `--engines vision` for a single-engine run. Full comparison
defaults to both. These local runs test the current Mac, not every supported Mac.

## Automated GitHub checks

The **ClipName macOS checks** workflow runs on relevant pushes to `main`, pull requests,
and manually from [GitHub Actions](https://github.com/DD1000/Transcriber/actions/workflows/clipname-macos.yml)
using **Run workflow**. Each run builds the app and runs the Swift filename tests,
Python scene-output validation tests, and generated-video smoke checks on Apple Silicon
runners for macOS 14, 15, and 26. Each version reports its own pass or failure; one
failure does not cancel the other versions. Dependencies use `Package.resolved`.

These checks do not download AI models or use personal videos. They do not establish
transcription or scene-recognition accuracy, UI/folder-permission behavior, or
rename/Undo safety. Those need separate end-to-end tests before release. No app is
installed on your Mac or deployed to the website by this workflow.

GitHub has scheduled its macOS 14 runners for retirement on November 2, 2026.
If that runner becomes unavailable, Sonoma testing will need another test machine;
an unavailable runner is not evidence that ClipName itself is incompatible.

## Public real-model tests on GitHub

The manually dispatched **ClipName real AI on free M1 runners** workflow exercises
the production speech and scene engines on the free public-repository labels
`macos-14`, `macos-15`, `macos-26`, and `xcode-27`. The last is a dedicated preview
configuration; its actual macOS version is recorded for each run. All four are
M1-based virtual machines; these are not tests of M2/M3/M4 hardware or the app UI.
The workflow refuses private repositories and does not request paid runner labels.

Only public/generated fixtures are used: a credited NASA Blue Marble image, two
original English/Spanish sentences synthesized using eSpeak NG standard formant
voices, and a silent scene clip. Source, usage terms and SHA-256 hashes are recorded
with every run. The personal `.private-tests` suite is never accessed or uploaded.
Tests only propose filenames; they never rename videos.

Each runner records its actual OS, toolchain, memory, dependency lock and source
commit. It builds ClipName, runs normal checks, probes Metal and MLX with real GPU
arithmetic, then attempts Whisper English/Spanish inference plus the no-audio
negative control. Qwen scene inference runs only after a working MLX GPU probe and
model setup. Model downloads are allowed; no audio/video is sent to an inference API.
Only public result JSON and process logs are uploaded, not media, model caches or
temporary frames. Artifacts expire after 30 days.

The report distinguishes completed model inference, expected no-audio handling,
failed tests, missing prerequisites, and a verified unavailable GPU. A green workflow
with an unavailable GPU does **not** establish that scene inference passed. Each
native model process has a ten-minute limit; step limits and a larger job budget
leave time for partial reporting. Timings include process startup, media preparation,
loading and inference, plus downloads only when triggered inside that process. Vision
is pre-downloaded and later speech tests may reuse weights; these are not chip-speed
comparisons. Normalized word error rates apply only to these
two synthetic sentences, not general Spanish or English accuracy. Scene descriptions
are recorded for human review, not automatically declared correct.
