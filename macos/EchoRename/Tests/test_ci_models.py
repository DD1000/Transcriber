"""Public CI reporting checks; no networks, model downloads or personal media."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("ci_models", SCRIPTS / "ci-model-benchmark.py")
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)


class PublicCIModelTests(unittest.TestCase):
    def test_normalized_word_error_rate(self):
        self.assertEqual(ci.word_error_rate("Cámara, océanos!", "camara oceanos"), 0)
        self.assertEqual(ci.word_error_rate("blue oceans", "green oceans"), 0.5)
        self.assertEqual(ci.word_error_rate("blue oceans", ""), 1)
        self.assertIsNone(ci.word_error_rate("", "extra"))

    def test_missing_probe_is_not_proof_gpu_unavailable(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            with mock.patch.dict(ci.os.environ, {}, clear=True):
                ci.summary(root)
            report = json.loads((root / "summary.json").read_text())
            self.assertEqual(len(report["models"]), 4)
            self.assertEqual(report["inferenceCompleted"], 0)
            self.assertEqual(report["models"][-1]["status"], "not_run")

    def test_control_cannot_inflate_real_inference_count(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            ci.write(root, "speech-results.json", [{
                "caseID": "silent-earth", "engine": "speech", "status": "completed",
                "inferenceExecuted": True, "evaluationType": "negative_control",
            }])
            ci.write(root, "mlx-probe.json", {"status": "unavailable", "operationExecuted": False})
            with mock.patch.dict(ci.os.environ, {}, clear=True):
                ci.summary(root)
            report = json.loads((root / "summary.json").read_text())
            self.assertEqual(report["inferenceCompleted"], 0)
            self.assertFalse(report["allInferenceCompleted"])
            self.assertEqual(report["models"][-1]["status"], "unavailable")

    def test_private_manifest_is_rejected_before_media_read(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            ci.write(root, "fixtures.json", {"privacy": "local-only", "cases": []})
            with self.assertRaisesRegex(ValueError, "Only generated public"):
                ci.run_models(root, root / "missing", "speech")


if __name__ == "__main__":
    unittest.main()
