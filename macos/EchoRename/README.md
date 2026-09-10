# ClipName for Mac

ClipName proposes descriptive video filenames from local speech transcription and visual scene analysis. Review and edit suggestions before pressing Rename. Duplicate names get numbered, and Undo restores the last completed rename batch.

## Scene naming

- **Speech + scenes** transcribes first, then uses sampled frames for short, empty, or unhelpful speech. Videos without an audio track also use scenes.
- **Scenes only** skips transcription for scenery, music videos, or clips whose speech doesn't describe their contents.
- Every visual suggestion is marked **Based on video scenes**, with an expandable scene description. Unreadable or unclear videos keep their names and show an explanation.

Four small frames are sampled across each video (one for clips shorter than a second). Scene descriptions can miss brief events or make mistakes; they are editable suggestions. English scene names are used; English and Spanish speech remain supported. Stop preserves completed suggestions. Stopping during speech waits for the current audio operation; scene workers are terminated promptly.

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
python3 -m unittest discover -s Tests -p 'test_scene_worker.py'
swiftc -parse-as-library Sources/EchoRename/VideoFrameSampler.swift Sources/EchoRename/SpeechNamingPolicy.swift Sources/EchoRename/TitleGenerator.swift scripts/smoke.swift -o /tmp/clipname-smoke
/tmp/clipname-smoke
```

The native smoke harness creates its own tiny test videos. It never renames user files.

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
