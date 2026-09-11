#!/usr/bin/env python3
"""Public-only GitHub model tests; never opens the private video test suite."""
import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import time
import unicodedata
import urllib.request

import benchmark

NASA_URL = "https://svs.gsfc.nasa.gov/vis/a030000/a030600/a030613/blue_marble_apollo_17_19721207_print.jpg"
NASA_SHA256 = "13419b34c17722be52b4a71a7f0beb3ecc8673183c8a2cee8572d5cd9bbe3f93"
TEXTS = {
    "english": "The camera shows planet Earth from space. White clouds float above blue oceans.",
    "spanish": "La cámara muestra el planeta Tierra desde el espacio. Hay nubes blancas sobre los océanos azules.",
}
PROJECT = Path(__file__).resolve().parents[1]
VISION_HOME = Path.home() / "Library/Application Support/ClipName/Vision"


def write(output, name, value):
    output.mkdir(parents=True, exist_ok=True)
    benchmark.save_json(output / name, value)


def checked(args):
    subprocess.run([str(a) for a in args], check=True, timeout=180)


def init(output):
    output.mkdir(parents=True, exist_ok=True)
    write(output, "environment.json", {
        "schemaVersion": 1, "privacy": "public-generated-fixtures-only", "startedAt": benchmark.timestamp(),
        "runnerLabel": os.environ.get("CLIPNAME_RUNNER_LABEL", "local"),
        "runnerImageVersion": os.environ.get("ImageVersion", "unknown"),
        "runnerImageOS": os.environ.get("ImageOS", "unknown"),
        "runURL": f"https://github.com/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}",
        "sourceCommit": os.environ.get("GITHUB_SHA", benchmark.command_text(["git", "rev-parse", "HEAD"])),
        "macOS": benchmark.command_text(["sw_vers", "-productVersion"]),
        "macOSBuild": benchmark.command_text(["sw_vers", "-buildVersion"]),
        "architecture": platform.machine(),
        "chip": benchmark.command_text(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "hardwareModel": benchmark.command_text(["sysctl", "-n", "hw.model"]),
        "memoryBytes": benchmark.command_text(["sysctl", "-n", "hw.memsize"]),
        "xcode": benchmark.command_text(["xcodebuild", "-version"]),
        "swift": benchmark.command_text(["swift", "--version"]),
        "diskFreeBytes": shutil.disk_usage(output).free,
        "dependencies": json.loads((PROJECT / "Package.resolved").read_text()),
    })


def fixtures(output, media):
    media.mkdir(parents=True, exist_ok=False)
    image = media / "earth.jpg"
    with urllib.request.urlopen(NASA_URL, timeout=60) as response, image.open("xb") as target:
        shutil.copyfileobj(response, target)
    if benchmark.fingerprint(image)["sha256"] != NASA_SHA256:
        raise ValueError("NASA test-image checksum mismatch")
    cases = []
    for name, text in TEXTS.items():
        wav, video = media / f"{name}.wav", media / f"{name}.mp4"
        checked(["espeak-ng", "-v", "en-us" if name == "english" else "es", "-s", "145", "-w", wav, text])
        checked(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-loop", "1", "-i", image,
                 "-i", wav, "-vf", "scale=512:512", "-r", "8", "-c:v", "libx264", "-tune", "stillimage",
                 "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", video])
        cases.append({"id": name, "filename": video.name, "referenceTranscript": text, **benchmark.fingerprint(video)})
    video = media / "silent-earth.mp4"
    checked(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-loop", "1", "-i", image,
             "-vf", "scale=512:512", "-r", "8", "-t", "4", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", video])
    cases.append({"id": "silent-earth", "filename": video.name, "referenceTranscript": None, **benchmark.fingerprint(video)})
    write(output, "fixtures.json", {
        "privacy": "public-generated-fixtures-only", "cases": cases,
        "imageSource": "https://svs.gsfc.nasa.gov/30613", "imageURL": NASA_URL, "imageSHA256": NASA_SHA256,
        "imageCredit": "NASA Johnson Space Center, Earth Science and Remote Sensing Unit",
        "imageRights": "NASA factual informational usage; no endorsement implied. https://www.nasa.gov/nasa-brand-center/images-and-media/",
        "speechSource": "Original project sentences synthesized with standard eSpeak NG en-us/es formant voices.",
        "speechRights": "Generated audio does not inherit the engine GPL: https://sourceforge.net/p/espeak/discussion/538920/thread/c6944a60/",
        "espeakVersion": benchmark.command_text(["espeak-ng", "--version"]),
        "expectedSceneConcepts": ["Earth or planet", "clouds", "oceans", "space"],
    })


def mlx_probe(output):
    result = {"status": "unavailable", "operationExecuted": False}
    try:
        import mlx.core as mx
        result["mlxVersion"] = importlib.metadata.version("mlx")
        result["metalAvailable"] = mx.metal.is_available()
        if result["metalAvailable"]:
            result["deviceInfo"] = mx.metal.device_info()
            mx.set_default_device(mx.gpu)
            values = mx.arange(16, dtype=mx.float32)
            total = mx.sum(values * 2)
            mx.eval(total)
            if total.item() != 240:
                raise ValueError("GPU arithmetic probe returned an incorrect value")
            result.update(status="completed", operationExecuted=True, defaultDevice=str(mx.default_device()))
        else:
            result["error"] = "MLX reports no Metal device in this hosted environment."
    except Exception as error:
        result["status"] = "failed"
        result["error"] = f"{type(error).__name__}: {error}"
    write(output, "mlx-probe.json", result)
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a") as handle:
        handle.write(f"available={'true' if result['operationExecuted'] else 'false'}\n")
    print(json.dumps(result))
    return 1 if result["status"] == "failed" else 0


def words(text):
    value = unicodedata.normalize("NFD", text.lower())
    value = "".join(c for c in value if not unicodedata.combining(c))
    return re.findall(r"\w+", value)


def word_error_rate(reference, actual):
    expected, observed = words(reference), words(actual)
    row = list(range(len(observed) + 1))
    for i, left in enumerate(expected, 1):
        following = [i]
        for j, right in enumerate(observed, 1):
            following.append(min(following[-1] + 1, row[j] + 1, row[j - 1] + (left != right)))
        row = following
    return row[-1] / len(expected) if expected else None


def run_models(output, media, engine):
    manifest = json.loads((output / "fixtures.json").read_text())
    if manifest.get("privacy") != "public-generated-fixtures-only":
        raise ValueError("Only generated public CI fixtures are allowed")
    executable = (PROJECT / ".build/debug/ClipName").resolve()
    selected = manifest["cases"] if engine == "speech" else [c for c in manifest["cases"] if c["id"] == "silent-earth"]
    results = []
    for case in selected:
        # Fixed manifest IDs and filenames prevent reads of arbitrary user media.
        if case["id"] not in {"english", "spanish", "silent-earth"} or case["filename"] != case["id"] + ".mp4":
            raise ValueError("Unexpected public fixture")
        video = media / case["filename"]
        if video.is_symlink() or benchmark.fingerprint(video) != {"sha256": case["sha256"], "bytes": case["bytes"]}:
            raise ValueError("Public fixture changed before evaluation")
        prefix = f"{case['id']}-{engine}"
        result = benchmark.evaluate(executable, engine, video, output / f"{prefix}.json", output / f"{prefix}.log", 600)
        negative_control = engine == "speech" and case["id"] == "silent-earth"
        result.update(caseID=case["id"], fixtureSHA256=case["sha256"], inferenceExecuted=not negative_control and result["status"] == "completed")
        result["inputUnchanged"] = benchmark.fingerprint(video) == {"sha256": case["sha256"], "bytes": case["bytes"]}
        if not result["inputUnchanged"]:
            result.update(status="failed", error="Fixture changed during evaluation")
        if engine == "speech" and case["referenceTranscript"] and result["status"] == "completed":
            result["referenceTranscript"] = case["referenceTranscript"]
            result["normalizedWordErrorRate"] = word_error_rate(case["referenceTranscript"], result.get("transcript", ""))
        result["evaluationType"] = "negative_control" if negative_control else "model_inference"
        if result["evaluationType"] == "negative_control":
            result["controlPassed"] = result["status"] == "no_audio"
        results.append(result)
        write(output, f"{engine}-results.json", results)
        print(f"{engine} {case['id']}: {result['status']}", flush=True)
    acceptable = all(r["status"] == ("no_audio" if r["evaluationType"] == "negative_control" else "completed") for r in results)
    return 0 if acceptable else 1


def summary(output):
    # Step outcomes come from GitHub, not success inferred from absent log files.
    stages = {key.removeprefix("CLIPNAME_STAGE_").lower(): value for key, value in os.environ.items() if key.startswith("CLIPNAME_STAGE_")}
    report = {"schemaVersion": 1, "finishedAt": benchmark.timestamp(), "stages": stages, "models": []}
    for name in ["environment", "fixtures", "metal-probe", "mlx-probe"]:
        path = output / f"{name}.json"
        report[name] = json.loads(path.read_text()) if path.exists() else {"status": "not_recorded"}
    for engine, case_ids in [("speech", ["english", "spanish", "silent-earth"]), ("vision", ["silent-earth"])]:
        path = output / f"{engine}-results.json"
        existing = json.loads(path.read_text()) if path.exists() else []
        indexed = {item["caseID"]: item for item in existing}
        for case_id in case_ids:
            if case_id in indexed:
                report["models"].append(indexed[case_id])
            else:
                unavailable = engine == "vision" and report["mlx-probe"].get("status") == "unavailable"
                reason = "MLX GPU probe unavailable; model inference was not run." if unavailable else "A prerequisite or model step did not complete; inspect stage outcomes."
                report["models"].append({"caseID": case_id, "engine": engine, "status": "unavailable" if unavailable else "not_run", "inferenceExecuted": False, "evaluationType": "negative_control" if engine == "speech" and case_id == "silent-earth" else "model_inference", "error": reason})
    report["inferenceCompleted"] = sum(row.get("inferenceExecuted") is True and row.get("evaluationType") == "model_inference" for row in report["models"])
    report["inferenceExpected"] = 3
    report["allInferenceCompleted"] = report["inferenceCompleted"] == report["inferenceExpected"]
    report["timingNote"] = "Isolated-process wall time includes media preparation, model loading and inference. Downloads are included only when triggered within that process; vision is pre-downloaded and later speech cases may reuse weights. Not a hardware speed ranking."
    write(output, "summary.json", report)
    with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a") as handle:
        handle.write(f"## ClipName public model test results\n\nReal model evaluations completed: {report['inferenceCompleted']}/3.\n\n")
        for row in report["models"]:
            handle.write(f"- {row['engine']} / {row['caseID']}: {row['status']}\n")
        handle.write("\nFull outputs and environment details are in the public-model-results artifact. Personal test videos were not used.\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["init", "fixtures", "probe", "speech", "vision", "summary"])
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--media", type=Path)
    args = parser.parse_args()
    def terminate(signum, frame):
        raise KeyboardInterrupt("CI test interrupted")
    signal.signal(signal.SIGTERM, terminate)
    if args.command == "init": init(args.output)
    elif args.command == "fixtures": fixtures(args.output, args.media)
    elif args.command == "probe": return mlx_probe(args.output)
    elif args.command in {"speech", "vision"}: return run_models(args.output, args.media, args.command)
    else: summary(args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
