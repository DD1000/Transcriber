#!/usr/bin/env python3
"""Private local video evaluations. Never uploads media or renames inputs.

Usage (from macos/EchoRename):
  python3 scripts/benchmark.py import '/path/to/test videos'
  swift build --product ClipName --force-resolved-versions
  python3 scripts/benchmark.py run
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

PROJECT = Path(__file__).resolve().parents[1]
PRIVATE = PROJECT / ".private-tests"
EXTENSIONS = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm"}


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def fingerprint(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"sha256": digest.hexdigest(), "bytes": path.stat().st_size}


def save_json(path, value):
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("x", encoding="utf-8") as target:
            json.dump(value, target, ensure_ascii=False, indent=2, allow_nan=False)
            target.write("\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def suite_path(name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", name):
        raise ValueError("Suite name must contain only letters, digits, underscores, or hyphens.")
    target = PRIVATE / name
    if PRIVATE.is_symlink() or target.is_symlink():
        raise ValueError("Private test directories must not be symlinks.")
    return target


def natural_key(path):
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", path.name)]


def import_videos(source, destination):
    if not source.is_dir():
        raise ValueError("Choose an existing folder of videos.")
    if destination.exists():
        raise ValueError("This suite already exists. Choose another --suite; existing tests are never overwritten.")
    videos = sorted((p for p in source.iterdir() if p.suffix.lower() in EXTENSIONS), key=natural_key)
    if not videos or any(p.is_symlink() or not p.is_file() for p in videos):
        raise ValueError("The folder must contain regular video files, not symlinks or folders with video extensions.")
    destination.mkdir(parents=True, mode=0o700)
    copied_folder = destination / "videos"
    copied_folder.mkdir(mode=0o700)
    manifest = {"schemaVersion": 1, "privacy": "local-only", "createdAt": timestamp(), "cases": []}
    for index, original in enumerate(videos, 1):
        before = fingerprint(original)
        target = copied_folder / original.name
        # Copy bytes only, not Finder metadata or source permissions. Source is read-only.
        with original.open("rb") as src, target.open("xb") as dst:
            shutil.copyfileobj(src, dst)
        if fingerprint(target) != before or fingerprint(original) != before:
            raise ValueError(f"Video {index} changed while being copied. Import is incomplete.")
        manifest["cases"].append({
            "id": f"video-{index:03d}", "file": f"videos/{original.name}", **before,
            "expectedTranscript": None, "expectedScene": None,
        })
    save_json(destination / "manifest.json", manifest)
    return manifest


def load_cases(suite):
    manifest = json.loads((suite / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1 or manifest.get("privacy") != "local-only":
        raise ValueError("Unsupported or non-private test manifest.")
    cases = manifest.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ValueError("The test manifest has no cases.")
    ids, paths = set(), set()
    for case in cases:
        if not re.fullmatch(r"video-\d{3,}", case.get("id", "")) or case["id"] in ids:
            raise ValueError("Invalid or duplicate case ID.")
        relative = Path(case["file"])
        if relative.is_absolute() or ".." in relative.parts or len(relative.parts) != 2 or relative.parts[0] != "videos":
            raise ValueError("Fixture paths must be direct children of the suite's videos folder.")
        path = suite / relative
        if (suite / "videos").is_symlink() or path.is_symlink() or not path.is_file() or path in paths:
            raise ValueError("Missing, duplicated, or symlinked video fixture.")
        if fingerprint(path) != {"sha256": case["sha256"], "bytes": case["bytes"]}:
            raise ValueError(f"Fixture {case['id']} changed since import; refusing to use an untracked test input.")
        ids.add(case["id"])
        paths.add(path)
    return cases


def command_text(arguments):
    try:
        result = subprocess.run(arguments, cwd=PROJECT, capture_output=True, text=True, timeout=10, check=True)
        return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "unavailable"


def source_fingerprint():
    digest = hashlib.sha256()
    for path in sorted((PROJECT / "Sources").rglob("*")) + [PROJECT / "Package.swift", PROJECT / "Package.resolved"]:
        if path.is_file():
            digest.update(str(path.relative_to(PROJECT)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def environment(executable):
    return {
        "macOS": command_text(["/usr/bin/sw_vers", "-productVersion"]),
        "macOSBuild": command_text(["/usr/bin/sw_vers", "-buildVersion"]),
        "architecture": platform.machine(),
        "chip": command_text(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]),
        "memoryBytes": command_text(["/usr/sbin/sysctl", "-n", "hw.memsize"]),
        "sourceCommit": command_text(["git", "rev-parse", "HEAD"]),
        "sourceDirty": command_text(["git", "status", "--porcelain"]) != "",
        "sourceSHA256": source_fingerprint(),
        "executableSHA256": fingerprint(executable)["sha256"],
        "dependencies": json.loads((PROJECT / "Package.resolved").read_text()),
        "timingNote": "Isolated process per model/video; wall time includes startup, model loading and media preparation, not pure inference. Model caches may already be warm.",
    }


def stop_group(process):
    # The worker may have its own child MLX process. Reap the entire test group.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def evaluate(executable, engine, video, result_file, log_file, timeout):
    start = time.monotonic()
    status = None
    with tempfile.TemporaryDirectory(prefix=".media-", dir=log_file.parent) as temporary, log_file.open("xb") as log:
        child_environment = os.environ.copy()
        child_environment["TMPDIR"] = temporary
        # Foundation on macOS ignores TMPDIR; the native test entry passes this
        # explicit root to the production audio/frame extractors instead.
        child_environment["CLIPNAME_BENCHMARK_TEMP"] = temporary
        process = subprocess.Popen(
            [str(executable), "--benchmark", engine, str(video), str(result_file)],
            stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            start_new_session=True, env=child_environment,
        )
        try:
            return_code = process.wait(timeout=timeout)
            if return_code < 0:
                # A crashed native parent can leave an MLX child until its
                # watchdog notices. Stop the group before removing its frames.
                stop_group(process)
        except subprocess.TimeoutExpired:
            stop_group(process)
            status = {"status": "timed_out", "error": f"Exceeded {timeout:g} seconds."}
            return_code = process.returncode
        except BaseException:
            stop_group(process)
            raise
    if status is None:
        try:
            status = json.loads(result_file.read_text(encoding="utf-8"))
            if not isinstance(status, dict) or status.get("schemaVersion") != 1 or status.get("engine") != engine or status.get("status") not in {"completed", "no_audio", "failed"}:
                raise ValueError("Malformed native result")
            if return_code != 0 and status["status"] != "failed":
                raise ValueError("The model process exited unsuccessfully despite its result")
        except (OSError, ValueError, TypeError):
            status = {"status": "crashed" if return_code < 0 else "failed", "error": "No valid model result. See the private log."}
    status.update({"engine": engine, "processExitCode": return_code, "wallSeconds": round(time.monotonic() - start, 3)})
    return status


def automatic_choice(case_result):
    results = case_result.get("results", {})
    speech, vision = results.get("speech", {}), results.get("vision", {})
    if not speech or speech.get("status") == "running":
        return {"source": "not_evaluated", "filename": Path(case_result["file"]).name}
    if speech.get("status") == "completed" and speech.get("usefulSpeech") and speech.get("suggestedFilename"):
        return {"source": "speech", "filename": speech["suggestedFilename"]}
    if vision.get("status") == "completed" and vision.get("suggestedFilename"):
        return {"source": "vision", "filename": vision["suggestedFilename"]}
    return {"source": "keep_original", "filename": Path(case_result["file"]).name}


def fenced(value):
    # Treat all model/user text as data, including Markdown fences.
    text = str(value)
    longest = max((len(match.group()) for match in re.finditer(r"`+", text)), default=0)
    fence = "`" * max(3, longest + 1)
    return f"{fence}text\n{text}\n{fence}\n"


def save_report(folder, report):
    save_json(folder / "results.json", report)
    machine = report["environment"]
    lines = ["# ClipName private video test results", "", f"Run status: {report['status']}", "",
             f"Machine: {machine['chip']} · macOS {machine['macOS']} · {machine['architecture']}", "",
             "These are model outputs, not accuracy scores. No reference transcripts or scene labels have been reviewed yet.", "",
             "Test videos are never renamed. Suggested names are before the app's duplicate-numbering step.", "",
             machine["timingNote"], ""]
    for case in report["cases"]:
        lines += [f"## {case['id']}", "", fenced(Path(case["file"]).name)]
        for engine, result in case["results"].items():
            lines += [f"### {engine.capitalize()}: {result['status']}", "",
                      f"Time: {result.get('wallSeconds', 0):.1f} seconds", ""]
            for key in ("modelID", "transcript", "sceneTitle", "sceneDescription", "suggestedFilename", "error"):
                if key in result:
                    lines += [f"{key}:", "", fenced(result[key])]
        if "automatic" in case:
            lines += [f"Automatic mode would use: {case['automatic']['source']}", "", fenced(case["automatic"]["filename"])]
    target = folder / "report.md"
    temporary = folder / ".report.md.tmp"
    temporary.write_text("\n".join(lines), encoding="utf-8")
    os.replace(temporary, target)


def run_suite(suite, executable, timeout, engines):
    cases = load_cases(suite)  # Verify all media before launching any model.
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("Build ClipName first; the native test executable is missing.")
    if len(engines) != len(set(engines)):
        raise ValueError("Choose each engine only once.")
    if (suite / "runs").is_symlink():
        raise ValueError("The private report directory must not be a symlink.")
    run_folder = suite / "runs" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])
    run_folder.mkdir(parents=True, mode=0o700)
    report = {
        "schemaVersion": 1, "privacy": "local-only", "startedAt": timestamp(), "status": "running",
        "environment": environment(executable), "accuracyReview": "not_scored",
        "cases": [{**case, "results": {}} for case in cases],
    }
    # Record checkout provenance. This does not assert a custom executable or
    # installed model weights match the checkout; retain their identities separately.
    worker = PROJECT / "Sources/EchoRename/Resources/scene_namer.py"
    report["checkoutVisionWorkerSHA256"] = fingerprint(worker)["sha256"]
    worker_text = worker.read_text()
    report["checkoutDeclaredVisionModelRevision"] = re.search(r'^MODEL_REVISION = "([a-f0-9]+)"', worker_text, re.M).group(1)
    save_report(run_folder, report)
    print(f"Private reports: {run_folder}", flush=True)
    try:
        for engine in engines:
            for index, case in enumerate(report["cases"], 1):
                print(f"{engine}: video {index}/{len(cases)}", flush=True)
                case["results"][engine] = {"status": "running"}
                save_report(run_folder, report)
                prefix = f"{case['id']}-{engine}"
                case["results"][engine] = evaluate(
                    executable, engine, suite / case["file"],
                    run_folder / f"{prefix}.json", run_folder / f"{prefix}.log", timeout,
                )
                if all(name in case["results"] for name in ["speech", "vision"]):
                    case["automatic"] = automatic_choice(case)
                save_report(run_folder, report)
                print(f"{engine}: video {index}/{len(cases)} {case['results'][engine]['status']}", flush=True)
        load_cases(suite)  # Hash verification: original fixture bytes/names remain intact.
        report["fixturesUnchanged"] = True
        bad = any(result["status"] not in {"completed", "no_audio"} for case in report["cases"] for result in case["results"].values())
        report["status"] = "completed_with_errors" if bad else "completed"
    except BaseException as error:
        report["status"] = "interrupted" if isinstance(error, KeyboardInterrupt) else "failed"
        report["error"] = str(error)
        for case in report["cases"]:
            for engine, result in case["results"].items():
                if result["status"] == "running":
                    case["results"][engine] = {"status": report["status"], "error": "Run stopped before this model returned."}
        raise
    finally:
        report["finishedAt"] = timestamp()
        save_report(run_folder, report)
    return run_folder, report


def main():
    os.umask(0o077)
    def terminate(signum, frame):
        raise KeyboardInterrupt("Test runner terminated")
    signal.signal(signal.SIGTERM, terminate)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    importer = sub.add_parser("import", help="Make private, hash-verified copies of local videos.")
    importer.add_argument("folder", type=Path)
    importer.add_argument("--suite", default="user-videos")
    runner = sub.add_parser("run", help="Record both production models on every video, without renaming.")
    runner.add_argument("--suite", default="user-videos")
    runner.add_argument("--engines", nargs="+", choices=["speech", "vision"], default=["speech", "vision"])
    runner.add_argument("--timeout", type=float, default=600, help="Per video/model wall-clock limit in seconds.")
    runner.add_argument("--executable", type=Path, default=PROJECT / ".build/debug/ClipName")
    args = parser.parse_args()
    try:
        suite = suite_path(args.suite)
        if args.command == "import":
            manifest = import_videos(args.folder.expanduser().resolve(), suite)
            print(f"Imported {len(manifest['cases'])} private test videos into {suite}")
        else:
            if not 0 < args.timeout <= 3600:
                raise ValueError("Timeout must be between 0 and 3600 seconds.")
            folder, report = run_suite(suite, args.executable.expanduser().resolve(), args.timeout, args.engines)
            print(f"{report['status']}: {folder / 'report.md'}")
            return 0 if report["status"] == "completed" else 1
    except (OSError, ValueError, KeyError) as error:
        print(f"Test setup error: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Stopped; completed results are saved privately.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
