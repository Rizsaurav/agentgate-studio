"""Tests for catalog_diff.py: python3 -m unittest discover -s mac/scripts -p 'test_*.py'"""
import copy
import unittest

from catalog_diff import compare, report

SHA = "a" * 64


def model(mid, files=(("Q8_0", "m-Q8_0.gguf", 1_000_000_000),), tools=True, licence="apache-2.0"):
    return {
        "id": mid, "name": mid, "publisher": "P", "licence": licence, "toolCalling": tools, "contextMax": 32768,
        "architecture": {"layers": 1, "kvHeads": 1, "headDim": 1},
        "gguf": {"repo": f"org/{mid}-GGUF", "files": [{"quant": q, "file": f, "bytes": b, "sha256": SHA} for q, f, b in files]},
        "source": {"repo": f"org/{mid}", "bytes": 1},
    }


def catalog(*models):
    return {"version": 1, "tiers": {}, "models": list(models)}


class CatalogDiffTests(unittest.TestCase):
    def test_no_change(self):
        old = catalog(model("a"))
        self.assertEqual(compare(old, copy.deepcopy(old)), ([], [], []))

    def test_new_model_is_scored_with_the_best_file_that_fits(self):
        big = model("b", files=(("Q8_0", "b-Q8_0.gguf", 9_000_000_000), ("Q4_K_M", "b-Q4_K_M.gguf", 2_000_000_000)))
        changes, notes, score = compare(catalog(model("a")), catalog(model("a"), big))
        self.assertEqual(changes, [])
        self.assertIn("New model", notes[0])
        self.assertEqual(score, [("b", "org/b-GGUF", "b-Q4_K_M.gguf", SHA)])

    def test_too_large_or_chat_only_models_are_not_scored(self):
        huge = model("h", files=(("Q4_K_M", "h.gguf", 20_000_000_000),))
        _, notes, score = compare(catalog(), catalog(huge, model("c", tools=False)))
        self.assertEqual(score, [])
        self.assertTrue(any("too large to score" in n for n in notes))

    def test_at_most_max_models_are_scored(self):
        new = catalog(model("a"), model("b"), model("c"))
        _, notes, score = compare(catalog(), new, max_models=2)
        self.assertEqual([m[0] for m in score], ["a", "b"])
        self.assertTrue(any("**c**: not scored" in n for n in notes))

    def test_changed_checksum_is_reported_and_fails(self):
        old = catalog(model("a"))
        new = copy.deepcopy(old)
        new["models"][0]["gguf"]["files"][0]["sha256"] = "b" * 64
        changes, _, _ = compare(old, new)
        self.assertEqual(len(changes), 1)
        self.assertIn("changed checksum", changes[0])
        self.assertIn("Nothing was scored", report(changes, [], []))

    def test_licence_gated_and_removed_are_flagged(self):
        old = catalog(model("a"), model("gone"), model("g"))
        gated = model("g", files=())
        del gated["source"]
        new = catalog(model("a", licence="other"), gated)
        _, notes, score = compare(old, new)
        text = "\n".join(notes)
        self.assertIn("Removed from the catalog: **gone**", text)
        self.assertIn("licence changed", text)
        self.assertIn("gated or removed", text)
        self.assertEqual(score, [])

    def test_a_new_quant_rescores_the_model(self):
        old = catalog(model("a"))
        new = catalog(model("a", files=(("Q8_0", "m-Q8_0.gguf", 1_000_000_000), ("Q4_K_M", "m-Q4_K_M.gguf", 500_000_000))))
        _, notes, score = compare(old, new)
        self.assertIn("new files", notes[0])
        self.assertEqual(score[0][2], "m-Q8_0.gguf")

    def test_other_changes_are_never_reported_as_no_change(self):
        old = catalog(model("a"))
        new = copy.deepcopy(old)
        new["models"][0]["contextMax"] = 65536
        _, notes, _ = compare(old, new)
        self.assertEqual(notes, ["**a**: other details changed; see the diff."])


if __name__ == "__main__":
    unittest.main()
