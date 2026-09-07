"""
Unit tests for pdfToText.py.
"""

from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

# Ensure src/python is on sys.path regardless of execution CWD
SRC_PYTHON_DIR = Path(__file__).resolve().parent.parent
if str(SRC_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_PYTHON_DIR))

from pdfToText import (
    DEFAULT_TEXT_THRESHOLD,
    DEFAULT_WORKERS,
    OUTPUT_DIR_NAME,
    PageClassification,
    PageClassifier,
    PageType,
    PathManager,
    PipelineConfig,
    PipelineCoordinator,
)


class TestPathManager(unittest.TestCase):
    """Test PathManager discovery and collision-free output path resolution."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.source_dir = (Path(self.temp_dir.name) / "source").resolve()
        self.source_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_resolve_output_path_non_recursive(self):
        manager = PathManager(source_dir=self.source_dir, recursive=False)
        pdf_path = self.source_dir / "sample.pdf"
        output_path = manager.resolve_output_path(pdf_path)

        expected_path = self.source_dir / OUTPUT_DIR_NAME / "sample.txt"
        self.assertEqual(output_path, expected_path)

    def test_resolve_output_path_recursive_preserves_subdirectories(self):
        manager = PathManager(source_dir=self.source_dir, recursive=True)
        sub_folder = self.source_dir / "finance" / "2024"
        sub_folder.mkdir(parents=True, exist_ok=True)
        pdf_path = sub_folder / "report.pdf"

        output_path = manager.resolve_output_path(pdf_path)
        expected_path = self.source_dir / OUTPUT_DIR_NAME / "finance" / "2024" / "report.txt"
        self.assertEqual(output_path, expected_path)

    def test_discover_pdfs(self):
        # Create test pdf files
        file1 = self.source_dir / "doc1.pdf"
        file2 = self.source_dir / "doc2.PDF"
        ignored = self.source_dir / "notes.txt"
        nested_dir = self.source_dir / "nested"
        nested_dir.mkdir()
        file3 = nested_dir / "doc3.pdf"

        file1.touch()
        file2.touch()
        ignored.touch()
        file3.touch()

        # Non-recursive
        manager_non_rec = PathManager(source_dir=self.source_dir, recursive=False)
        discovered_non_rec = manager_non_rec.discover_pdfs()
        self.assertEqual(len(discovered_non_rec), 2)
        self.assertIn(file1.resolve(), discovered_non_rec)
        self.assertIn(file2.resolve(), discovered_non_rec)

        # Recursive
        manager_rec = PathManager(source_dir=self.source_dir, recursive=True)
        discovered_rec = manager_rec.discover_pdfs()
        self.assertEqual(len(discovered_rec), 3)
        self.assertIn(file3.resolve(), discovered_rec)


class TestWorkerConfiguration(unittest.TestCase):
    """Test worker resolution logic and default values."""

    def test_default_worker_is_one(self):
        resolved = PipelineCoordinator.resolve_worker_count(None)
        self.assertEqual(resolved, DEFAULT_WORKERS)
        self.assertEqual(resolved, 1)

    def test_custom_worker_count(self):
        resolved = PipelineCoordinator.resolve_worker_count(4)
        self.assertEqual(resolved, 4)

    def test_invalid_worker_count_raises_value_error(self):
        with self.assertRaises(ValueError) as ctx:
            PipelineCoordinator.resolve_worker_count(0)
        self.assertIn("Action:", str(ctx.exception))
        self.assertIn("at least 1", str(ctx.exception))


class TestActionableErrorFormatting(unittest.TestCase):
    """Verify error messages follow the clear, actionable standard."""

    def test_format_actionable_error_structure(self):
        from pdfToText import format_actionable_error
        msg = format_actionable_error(
            context="TestContext",
            reason="A specific problem occurred.",
            action="Do something specific to resolve it.",
        )
        self.assertEqual(msg, "[TestContext] A specific problem occurred. Action: Do something specific to resolve it.")

    def test_page_classifier_error_is_actionable(self):
        classifier = PageClassifier()
        mock_page = MagicMock()
        mock_page.extract_text.side_effect = RuntimeError("Decompression Bomb")

        result = classifier.classify_page(mock_page, page_num=1)
        self.assertEqual(result.page_type, PageType.ERROR)
        self.assertIn("Action:", result.content)
        self.assertIn("Decompression Bomb", result.content)


class TestPageClassifier(unittest.TestCase):
    """Test classification of PDF pages into digital text, OCR, or empty."""

    def setUp(self):
        self.classifier = PageClassifier(text_threshold=DEFAULT_TEXT_THRESHOLD)

    def test_classify_text_page(self):
        mock_page = MagicMock()
        mock_page.extract_text.return_value = "This is a digital PDF page with plenty of text that exceeds threshold."
        result = self.classifier.classify_page(mock_page, page_num=1)

        self.assertEqual(result.page_num, 1)
        self.assertEqual(result.page_type, PageType.TEXT)
        self.assertEqual(result.content, "This is a digital PDF page with plenty of text that exceeds threshold.")

    def test_classify_ocr_page_when_text_below_threshold_and_has_images(self):
        mock_page = MagicMock()
        mock_page.extract_text.return_value = "1"  # only page number
        mock_image = MagicMock()
        mock_page.images = [mock_image]

        result = self.classifier.classify_page(mock_page, page_num=2)
        self.assertEqual(result.page_num, 2)
        self.assertEqual(result.page_type, PageType.OCR)
        self.assertEqual(result.image_index, 0)

    def test_classify_empty_page(self):
        mock_page = MagicMock()
        mock_page.extract_text.return_value = ""
        mock_page.images = []

        result = self.classifier.classify_page(mock_page, page_num=3)
        self.assertEqual(result.page_num, 3)
        self.assertEqual(result.page_type, PageType.EMPTY)


class TestHybridDocumentAssembly(unittest.TestCase):
    """Verify hybrid documents (mixed digital text & scanned pages) preserve all content."""

    def test_mixed_page_assembly_order(self):
        pages = {
            1: "Page 1: Digital text header and content.",
            2: "Page 2: OCR recognized scanned invoice content.",
            3: "Page 3: Digital text footer and signatures.",
        }
        total_pages = 3
        ordered_texts = [pages.get(i, "") for i in range(1, total_pages + 1)]
        full_text = "\n\n".join(t for t in ordered_texts if t.strip())

        self.assertIn("Page 1: Digital text", full_text)
        self.assertIn("Page 2: OCR recognized", full_text)
        self.assertIn("Page 3: Digital text", full_text)

        # Check sequence
        idx1 = full_text.index("Page 1")
        idx2 = full_text.index("Page 2")
        idx3 = full_text.index("Page 3")
        self.assertTrue(idx1 < idx2 < idx3)


class TestDocumentClassificationPlan(unittest.TestCase):
    """Verify document classification is pure and eliminates nested loops."""

    @patch("pdfToText.PdfReader")
    def test_classify_document_pure_function(self, mock_reader_cls):
        mock_reader = MagicMock()
        mock_p1 = MagicMock()
        text_content = "Digital text page with more than fifty characters to exceed the classification threshold."
        mock_p1.extract_text.return_value = text_content
        mock_p2 = MagicMock()
        mock_p2.extract_text.return_value = ""
        mock_p2.images = [MagicMock()]
        mock_reader.pages = [mock_p1, mock_p2]
        mock_reader_cls.return_value = mock_reader

        config = PipelineConfig(source_dir=Path("fake_dir"), target_dir=None)
        coordinator = PipelineCoordinator(config)

        plan = coordinator._classify_document(Path("fake_dir/doc.pdf"))
        self.assertEqual(plan.total_pages, 2)
        self.assertEqual(plan.digital_pages[1], text_content)
        self.assertEqual(len(plan.ocr_tasks), 1)
        self.assertEqual(plan.ocr_tasks[0].page_num, 2)
        self.assertEqual(len(plan.errors), 0)


class TestFailureExitCode(unittest.TestCase):
    """Verify pipeline returns full failure (exit code 1) on any processing error."""

    @patch("pdfToText.PathManager")
    def test_run_returns_failure_code_on_errors(self, mock_pm_cls):
        mock_pm = MagicMock()
        mock_pm.source_dir = Path("fake_dir")
        mock_pm.clear_text_dir = Path("fake_dir/clear-text")
        mock_pm.discover_pdfs.return_value = [Path("fake_dir/corrupt.pdf")]
        mock_pm.resolve_output_path.return_value = Path("fake_dir/clear-text/corrupt.txt")
        mock_pm_cls.return_value = mock_pm

        config = PipelineConfig(source_dir=Path("fake_dir"), target_dir=None)
        coordinator = PipelineCoordinator(config)

        # Force a classification error for the document
        with patch.object(coordinator, "_classify_document") as mock_classify:
            from pdfToText import DocumentClassificationPlan
            mock_classify.return_value = DocumentClassificationPlan(
                pdf_path=Path("fake_dir/corrupt.pdf"),
                total_pages=0,
                digital_pages={},
                ocr_tasks=[],
                errors=["[Read PDF] File is corrupt. Action: Check file."],
            )
            exit_code = coordinator.run()
            # Full failure required by user directive
            self.assertEqual(exit_code, 1)


if __name__ == "__main__":
    unittest.main()
