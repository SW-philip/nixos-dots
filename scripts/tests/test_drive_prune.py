import importlib.util
import os
import tempfile
import unittest
import zipfile

_spec = importlib.util.spec_from_file_location(
    "drive_prune", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "drive-prune.py"))
dp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dp)


def doc(name, body):
    f = {"path": f"mine/{name}", "sha": name, "mtime": "2026-01-01", "size": 1, "id": None, "media": False}
    return dict(f, text=body)


class DriveIds(unittest.TestCase):
    def test_unique_and_same_named(self):
        listing = [{"Path": "a.docx", "ID": "AAAA1111"}, {"Path": "b.docx", "ID": "0Bz-xxxxB1B1B1B1"},
                   {"Path": "b.docx", "ID": "0Bz-xxxxC2C2C2C2"}, {"Path": "noext", "ID": "x0Bz-D3D3D3D3"},
                   {"Path": "noext", "ID": "x0Bz-E4E4E4E4"}]
        self.assertEqual(dp.drive_ids(listing), {
            "a.docx": "AAAA1111",
            "b (B1B1B1B1).docx": "0Bz-xxxxB1B1B1B1", "b (C2C2C2C2).docx": "0Bz-xxxxC2C2C2C2",
            "noext (D3D3D3D3)": "x0Bz-D3D3D3D3", "noext (E4E4E4E4)": "x0Bz-E4E4E4E4"})


class OfficeText(unittest.TestCase):
    def test_reads_docx_skips_binary_doc(self):
        with tempfile.TemporaryDirectory() as d:
            for name in ("x.docx", "x.doc"):
                with zipfile.ZipFile(os.path.join(d, name), "w") as z:
                    z.writestr("word/document.xml", "<w:t>hello &amp; bye</w:t>")
            self.assertEqual(dp.office_text(os.path.join(d, "x.docx")), ("hello & bye", False))
            self.assertEqual(dp.office_text(os.path.join(d, "x.doc")), (None, False))


class Dups(unittest.TestCase):
    def test_keeps_plain_name_over_id_copy(self):
        files = [dict(doc("Amber (MaXSCFq8).docx", ""), sha="h"), dict(doc("Amber.docx", ""), sha="h")]
        (g,) = dp.find_dups(files)
        self.assertEqual([(f["path"], f["suggest"]) for f in g["files"]],
                         [("mine/Amber.docx", "keep"), ("mine/Amber (MaXSCFq8).docx", "delete")])


class Versions(unittest.TestCase):
    poem = " ".join(f"word{i}" for i in range(60))

    def test_drafts_link_but_never_suggest_delete(self):
        a = doc("ATPF.docx", self.poem)
        b = dict(doc("ATPFWrewrite.docx", self.poem + " plus a new ending"), mtime="2026-02-01")
        (g,) = dp.find_versions([a, b])
        self.assertEqual([f["suggest"] for f in g["files"]], ["keep", "review"])
        self.assertEqual(g["files"][0]["path"], "mine/ATPFWrewrite.docx")

    def test_poem_inside_collection_not_linked(self):
        other = " ".join(f"other{i}" for i in range(400))
        self.assertEqual(dp.find_versions([doc("poem.docx", self.poem), doc("collected.docx", self.poem + " " + other)]), [])

    def test_unrelated_same_name_not_linked(self):
        self.assertEqual(dp.find_versions([doc("April 3.docx", self.poem),
                                           doc("April 14.docx", " ".join(f"x{i}" for i in range(60)))]), [])


class OfficeTextXlsx(unittest.TestCase):
    def test_shared_strings_resolved(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "x.xlsx")
            with zipfile.ZipFile(p, "w") as z:
                z.writestr("xl/sharedStrings.xml", "<sst><si><t>Frosted</t></si><si><t>Flakes</t></si></sst>")
                z.writestr("xl/worksheets/sheet1.xml",
                           '<row><c r="A1" t="s" s="2"><v>1</v></c><c r="B1"><v>7</v></c></row>'
                           '<row><c r="A2" s="3"/><c r="B2" t="s"><v>0</v></c></row>')
            self.assertEqual(dp.office_text(p), ("Flakes 7\nFrosted", False))


GROUP = {"reason": "duplicate", "detail": "identical contents", "files": [
    dict(doc("a.docx", ""), id="ID_A", suggest="keep"),
    dict(doc("a (12345678).docx", ""), id="ID_B", suggest="delete"),
    dict(doc("a (87654321).docx", ""), id="ID_C", suggest="delete")]}


class Review(unittest.TestCase):
    group = GROUP

    def test_suggested_deletes_first_and_preselected(self):
        self.assertEqual([ln.split("\t")[0] for ln in dp.fzf_lines(self.group)],
                         ["mine/a (12345678).docx", "mine/a (87654321).docx", "mine/a.docx"])
        self.assertIn("--bind=load:toggle+down+toggle+down+first", dp.fzf_args(self.group, 1, 1, "p"))

    def test_parse(self):
        self.assertEqual(dp.parse_fzf("ctrl-s\nmine/a.docx\tx\n"), ("skip", set()))
        self.assertEqual(dp.parse_fzf("\nmine/a (12345678).docx\tx\n"), ("decide", {"mine/a (12345678).docx"}))
        # become(true) when nothing is selected: fzf prints nothing at all
        self.assertEqual(dp.parse_fzf(""), ("decide", set()))

    def test_record_last_decision_wins(self):
        with tempfile.TemporaryDirectory() as d:
            dp.record(d, self.group, {"mine/a (12345678).docx"})
            dp.record(d, self.group, set())
            self.assertEqual(dp.load_decisions(d), {"ID_A": "keep", "ID_B": "keep", "ID_C": "keep"})
            dp.record(d, self.group, {"mine/a (87654321).docx"})
            self.assertEqual(dp.load_decisions(d)["ID_C"], "delete")


class Apply(unittest.TestCase):
    def test_moves_writes_skip_lists_and_restores(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "mine"))
            os.makedirs(os.path.join(root, ".prune"))
            for name in ("a.docx", "a (12345678).docx", "Notes (20240101).docx", "keep.docx"):
                open(os.path.join(root, "mine", name), "w").close()
            dp.append(os.path.join(root, ".prune"), [
                ("x" * 20 + "12345678", "delete", "mine/a (12345678).docx", "duplicate"),
                ("path:mine/a.docx", "delete", "mine/a.docx", "duplicate"),
                ("IDNOTES0", "delete", "mine/Notes (20240101).docx", "rule"),
                ("IDKEEP00", "keep", "mine/keep.docx", "empty")])
            dp.apply(root)
            self.assertEqual(sorted(os.listdir(os.path.join(root, "mine"))),
                             [".prune-exclude", ".prune-ids", "keep.docx"])
            with open(os.path.join(root, "mine", ".prune-exclude")) as fh:
                # the ID copy is skipped by ID; a name that merely looks like one is filtered
                self.assertEqual(fh.read(), "/Notes (20240101).docx\n/a.docx\n")
            with open(os.path.join(root, "mine", ".prune-ids")) as fh:
                self.assertEqual(fh.read(), "IDNOTES0\n" + "x" * 20 + "12345678\n")
            dp.restore(root, ".pruned/mine/a.docx")
            self.assertTrue(os.path.exists(os.path.join(root, "mine", "a.docx")))
            with open(os.path.join(root, "mine", ".prune-exclude")) as fh:
                self.assertEqual(fh.read(), "/Notes (20240101).docx\n")

    def test_filter_escapes_glob_chars(self):
        self.assertEqual(dp.rclone_filter("d/***[x]{y}?.docx"), "/d/\\*\\*\\*\\[x\\]\\{y\\}\\?.docx")


class PurgeTargets(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        for d in ("mine", ".pruned/mine", ".prune"):
            os.makedirs(os.path.join(self.root, d))

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, rel, body):
        with open(os.path.join(self.root, rel), "w") as fh:
            fh.write(body)

    def decide(self, *rows):
        dp.append(os.path.join(self.root, ".prune"), rows)

    def ids(self):
        targets, manual, _ = dp.purge_targets(self.root)
        return sorted(k for k, _, _ in targets), manual

    def test_spares_drive_file_behind_kept_plain_copy(self):
        self.put("mine/Amber.docx", "same")
        self.put(".pruned/mine/Amber (AAAAAAAA).docx", "same")
        self.put(".pruned/mine/Amber (BBBBBBBB).docx", "same")
        self.decide(("path:mine/Amber.docx", "keep", "mine/Amber.docx", "duplicate"),
                    ("x-AAAAAAAA", "delete", "mine/Amber (AAAAAAAA).docx", "duplicate"),
                    ("x-BBBBBBBB", "delete", "mine/Amber (BBBBBBBB).docx", "duplicate"))
        self.assertEqual(self.ids(), (["x-BBBBBBBB"], []))

    def test_nothing_spared_when_a_live_sibling_holds_the_content(self):
        self.put("mine/Bead.docx", "same")
        self.put("mine/Bead (CCCCCCCC).docx", "same")
        self.put(".pruned/mine/Bead (DDDDDDDD).docx", "same")
        self.decide(("x-DDDDDDDD", "delete", "mine/Bead (DDDDDDDD).docx", "duplicate"))
        self.assertEqual(self.ids(), (["x-DDDDDDDD"], []))

    def test_unsure_is_spared(self):
        self.put("mine/Odd.docx", "kept")
        self.put(".pruned/mine/Odd (EEEEEEEE).docx", "different")
        self.decide(("x-EEEEEEEE", "delete", "mine/Odd (EEEEEEEE).docx", "duplicate"))
        self.assertEqual(self.ids(), ([], []))

    def test_shared_is_manual_and_purged_ids_drop_out(self):
        self.put(".pruned/mine/junk.docx", "")
        self.decide(("ID_JUNK", "delete", "mine/junk.docx", "empty"),
                    ("ID_SH", "delete", "shared/cover.png", "duplicate"),
                    ("path:mine/x.docx", "delete", "mine/x.docx", "duplicate"))
        self.assertEqual(self.ids(), (["ID_JUNK"], ["shared/cover.png"]))
        with open(os.path.join(self.root, ".prune", "purged.tsv"), "w") as fh:
            fh.write("ID_JUNK\tmine/junk.docx\tf\t2026-10-30\n")
        self.assertEqual(self.ids(), ([], ["shared/cover.png"]))


if __name__ == "__main__":
    unittest.main()
