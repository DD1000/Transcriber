"""Test benchmark plumbing with synthetic bytes and fake processes, never user videos or AI."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("benchmark", Path(__file__).resolve().parents[1] / "scripts/benchmark.py")
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)


class BenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        for index in (10, 2, 1):
            (self.source / f"unnamed {index}.mp4").write_bytes(bytes([index]) * 100)
        self.suite = self.root / "suite"

    def test_import_copies_in_natural_order_and_preserves_originals(self):
        before = {p.name: benchmark.fingerprint(p) for p in self.source.iterdir()}
        manifest = benchmark.import_videos(self.source, self.suite)
        self.assertEqual([c["file"] for c in manifest["cases"]], [f"videos/unnamed {i}.mp4" for i in (1, 2, 10)])
        self.assertEqual(before, {p.name: benchmark.fingerprint(p) for p in self.source.iterdir()})
        self.assertEqual(len(benchmark.load_cases(self.suite)), 3)
        self.assertTrue(all(c["expectedTranscript"] is None for c in manifest["cases"]))
        self.assertEqual(manifest["privacy"], "local-only")
        self.assertNotIn(str(self.source), json.dumps(manifest))

    def test_import_refuses_overwrite_and_symlinks(self):
        benchmark.import_videos(self.source, self.suite)
        with self.assertRaises(ValueError):
            benchmark.import_videos(self.source, self.suite)
        (self.source / "linked.mp4").symlink_to(self.source / "unnamed 1.mp4")
        with self.assertRaises(ValueError):
            benchmark.import_videos(self.source, self.root / "second")

    def test_changed_fixture_is_rejected(self):
        benchmark.import_videos(self.source, self.suite)
        (self.suite / "videos/unnamed 1.mp4").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "changed since import"):
            benchmark.load_cases(self.suite)

    def test_manifest_cannot_escape_or_duplicate_input(self):
        manifest = benchmark.import_videos(self.source, self.suite)
        manifest["cases"][0]["file"] = "../source/unnamed 1.mp4"
        benchmark.save_json(self.suite / "manifest.json", manifest)
        with self.assertRaisesRegex(ValueError, "direct children"):
            benchmark.load_cases(self.suite)
        manifest["cases"][0]["file"] = "videos/unnamed 2.mp4"
        benchmark.save_json(self.suite / "manifest.json", manifest)
        with self.assertRaises(ValueError):
            benchmark.load_cases(self.suite)

    def test_suite_name_cannot_escape_private_folder(self):
        for name in ("../outside", "/tmp/test", "", "a/b"):
            with self.assertRaises(ValueError):
                benchmark.suite_path(name)

    def test_automatic_mode_uses_useful_speech_then_scenes(self):
        case = {"file": "videos/unnamed 1.mp4", "results": {
            "speech": {"status": "completed", "usefulSpeech": True, "suggestedFilename": "speech.mp4"},
            "vision": {"status": "completed", "suggestedFilename": "scene.mp4"},
        }}
        self.assertEqual(benchmark.automatic_choice(case), {"source": "speech", "filename": "speech.mp4"})
        case["results"]["speech"]["usefulSpeech"] = False
        self.assertEqual(benchmark.automatic_choice(case)["source"], "vision")
        case["results"]["vision"]["status"] = "failed"
        self.assertEqual(benchmark.automatic_choice(case)["filename"], "unnamed 1.mp4")
        del case["results"]["speech"]
        self.assertEqual(benchmark.automatic_choice(case)["source"], "not_evaluated")

    def test_markdown_model_text_is_fenced_as_data(self):
        output = benchmark.fenced("```\n# This is model text, not a report heading")
        self.assertTrue(output.startswith("````text\n"))
        self.assertTrue(output.endswith("````\n"))

    def test_native_errors_and_timeouts_are_not_passes(self):
        process = mock.Mock(pid=12345, returncode=-15)
        process.wait.side_effect = [subprocess.TimeoutExpired("fake", 1), -15, -15]
        with mock.patch.object(benchmark.subprocess, "Popen", return_value=process), mock.patch.object(benchmark.os, "killpg") as kill:
            result = benchmark.evaluate(Path("/fake"), "speech", self.source / "unnamed 1.mp4", self.root / "result.json", self.root / "run.log", 1)
        self.assertEqual(result["status"], "timed_out")
        self.assertEqual(kill.call_count, 2)
        process = mock.Mock(pid=12345, returncode=0)
        process.wait.return_value = 0
        with mock.patch.object(benchmark.subprocess, "Popen", return_value=process):
            result = benchmark.evaluate(Path("/fake"), "speech", self.source / "unnamed 1.mp4", self.root / "missing.json", self.root / "missing.log", 1)
        self.assertEqual(result["status"], "failed")

    def test_well_formed_native_output_is_logged(self):
        target = self.root / "result.json"
        benchmark.save_json(target, {"schemaVersion": 1, "engine": "speech", "status": "completed", "transcript": "A test transcript."})
        process = mock.Mock(pid=12345, returncode=0)
        process.wait.return_value = 0
        with mock.patch.object(benchmark.subprocess, "Popen", return_value=process):
            result = benchmark.evaluate(Path("/fake"), "speech", self.source / "unnamed 1.mp4", target, self.root / "ok.log", 1)
        self.assertEqual(result["transcript"], "A test transcript.")
        self.assertEqual(result["status"], "completed")
        self.assertGreaterEqual(result["wallSeconds"], 0)

    def test_owned_media_directory_is_removed_after_failure(self):
        process = mock.Mock(pid=12345, returncode=1)
        process.wait.return_value = 1
        media_folders = []
        def launch(*args, **kwargs):
            folder = Path(kwargs["env"]["CLIPNAME_BENCHMARK_TEMP"])
            self.assertEqual(folder.parent, self.root)
            (folder / "temporary-audio.m4a").write_bytes(b"private test bytes")
            media_folders.append(folder)
            return process
        with mock.patch.object(benchmark.subprocess, "Popen", side_effect=launch):
            result = benchmark.evaluate(Path("/fake"), "speech", self.source / "unnamed 1.mp4", self.root / "missing.json", self.root / "cleanup.log", 1)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(len(media_folders), 1)
        self.assertFalse(media_folders[0].exists())
        self.assertTrue((self.source / "unnamed 1.mp4").exists())


if __name__ == "__main__":
    unittest.main()
