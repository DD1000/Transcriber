"""Run with Python unittest; the model is not required for output-validation tests."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("scene_namer", Path(__file__).parents[1] / "Sources/EchoRename/Resources/scene_namer.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class SceneResultTests(unittest.TestCase):
    def test_valid_scene(self):
        result = worker.parse_description('{"title": "Waves at sunset", "description": "Ocean waves beneath an orange sky."}')
        self.assertEqual(result["title"], "Waves at sunset")

    def test_no_filenames_for_unclear_scenes(self):
        for title in ["", "unknown", "unclear scene", "black screen"]:
            with self.assertRaises(ValueError):
                worker.parse_description('{"title": "' + title + '", "description": "Unclear"}')

    def test_model_output_cannot_create_paths(self):
        result = worker.parse_description('{"title": "../../Beach: sunset / waves", "description": "Beach"}')
        self.assertEqual(result["title"], "Beach sunset waves")

    def test_incomplete_output(self):
        for value in ['{"title": null}', '{"title": ["beach"], "description": "Beach"}', 'not JSON']:
            with self.assertRaises(ValueError):
                worker.parse_description(value)


if __name__ == "__main__":
    unittest.main()
