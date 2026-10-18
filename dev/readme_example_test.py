"""The README's first Gleam block is the compiled `readme_call` example."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ReadmeExampleTests(unittest.TestCase):
    def test_make_a_call_snippet_is_the_compiled_example(self):
        readme = (ROOT / "README.md").read_text()
        match = re.search(r"```gleam\n(.*?)```", readme, re.S)
        self.assertIsNotNone(match, "README has no Gleam block")
        compiled = (ROOT / "examples/consumer/src/readme_call.gleam").read_text()
        self.assertEqual(
            match.group(1).strip(),
            compiled.strip(),
            "README snippet drifted from examples/consumer/src/readme_call.gleam",
        )


if __name__ == "__main__":
    unittest.main()
