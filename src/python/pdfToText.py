"""
pdfToText.py

Reviews every PDF in a source directory and decides, per page, whether it
already has an extractable text layer ("text-based") or whether it is a
scanned/image page that needs OCR. Text-based pages are extracted directly
from their embedded text layer; scanned pages are OCR'd (via RapidOCR) using
a worker process pool.

All resulting text files are written into a `clear-text` sub-folder (created
under --target, or under the source directory if --target is omitted), one
.txt file per PDF, mirroring the directory structure when recursive.

OCR parallelism is configured with:
    --workers N      number of worker processes to use for OCR (default: 1)

GPU capability is checked first thing on startup. If no working GPU execution
provider is found, OCR runs on CPU only with diagnostic hints. Pass --check-gpu
to run just that check and exit.

Usage:
    python pdfToText.py --check-gpu
    python pdfToText.py SOURCE_DIR [--target TARGET_DIR] [--workers N]
                         [--text-threshold N] [--max-dimension N]
                         [--recursive] [--overwrite] [--dry-run] [--verbose]
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from enum import Enum
import io
import logging
from multiprocessing import Pool, cpu_count
import os
from pathlib import Path
import sys
import time
from typing import Any, Dict, List, NamedTuple, Optional, Tuple

import numpy as np # pyright: ignore[reportMissingImports]
from PIL import Image # pyright: ignore[reportMissingImports]
from pypdf import PdfReader # pyright: ignore[reportMissingImports]

# Configure stream encoding safely
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8") # pyright: ignore[reportAttributeAccessIssue]
    except (AttributeError, io.UnsupportedOperation):
        pass

logger = logging.getLogger("pdfToText")


# --------------------------------------------------------------------------- #
# Constants and Enums
# --------------------------------------------------------------------------- #

DEFAULT_WORKERS = 1
DEFAULT_TEXT_THRESHOLD = 50
DEFAULT_CHUNK_SIZE = 2
DEFAULT_ORT_LOG_LEVEL = 4  # 4 = fatal only in onnxruntime
OUTPUT_DIR_NAME = "clear-text"
SUPPORTED_EXTENSION = ".pdf"
OUTPUT_EXTENSION = ".txt"


class PageType(Enum):
    TEXT = "text"
    OCR = "ocr"
    EMPTY = "empty"
    ERROR = "error"


class PageClassification(NamedTuple):
    page_num: int
    page_type: PageType
    content: str
    image_index: int = 0


class OcrTask(NamedTuple):
    pdf_path: str
    page_num: int
    total_pages: int
    image_index: int = 0


def format_actionable_error(context: str, reason: str, action: str) -> str:
    """
    Formats a structured error message containing context, root cause,
    and concrete, actionable steps for the user or operator.
    """
    return f"[{context}] {reason} Action: {action}"


class OcrResult(NamedTuple):
    pdf_path: str
    page_num: int
    text: str
    error: Optional[str] = None
    used_gpu: bool = False


@dataclass(frozen=True)
class DocumentClassificationPlan:
    """Immutable result of single-document classification without side effects."""
    pdf_path: Path
    total_pages: int
    digital_pages: Dict[int, str]
    ocr_tasks: List[OcrTask]
    errors: List[str]


# --------------------------------------------------------------------------- #
# Configuration Dataclass
# --------------------------------------------------------------------------- #

@dataclass(frozen=True)
class PipelineConfig:
    source_dir: Optional[Path]
    target_dir: Optional[Path]
    workers: int = DEFAULT_WORKERS
    text_threshold: int = DEFAULT_TEXT_THRESHOLD
    max_dimension: Optional[int] = None
    recursive: bool = False
    overwrite: bool = False
    dry_run: bool = False
    check_gpu: bool = False
    verbose: bool = False


# --------------------------------------------------------------------------- #
# GPU Capabilities Detector
# --------------------------------------------------------------------------- #

class GpuCapabilityDetector:
    """Detects and validates working ONNX Runtime GPU / CUDA execution providers."""

    _nvidia_dlls_registered: bool = False

    @classmethod
    def register_nvidia_dll_directories(cls) -> None:
        """
        On Windows, registers any NVIDIA DLL directories from site-packages
        (e.g. nvidia-cudnn-cu12, nvidia-cublas) into the process DLL search path.

        Also calls onnxruntime's own `preload_dlls()`, which newer onnxruntime-gpu
        releases (1.20+) require to register the CUDA execution provider as a
        "plugin EP" -- without it, CreateExecutionProviderFactoryInstance fails
        to find CUDAExecutionProvider even when every DLL above is reachable.

        Runs only once per process: repeating the DLL-directory registration and
        preload_dlls() call after the CUDA plugin EP has already registered corrupts
        the cuBLAS/cuDNN load state (symptom: "Could not locate cublasLt64_12.dll"
        on the second and later attempts, even though the first attempt succeeded).
        """
        if cls._nvidia_dlls_registered:
            return
        cls._nvidia_dlls_registered = True
        if sys.platform != "win32":
            return
        try:
            site_packages = Path(sys.prefix) / "Lib" / "site-packages"
            nvidia_path = site_packages / "nvidia"
            if nvidia_path.is_dir():
                for dll_file in nvidia_path.rglob("*.dll"):
                    dll_dir = str(dll_file.parent)
                    if hasattr(os, "add_dll_directory"):
                        try:
                            os.add_dll_directory(dll_dir)
                        except Exception:
                            pass
                    current_path = os.environ.get("PATH", "")
                    if dll_dir not in current_path:
                        os.environ["PATH"] = dll_dir + os.pathsep + current_path
        except Exception:
            pass
        try:
            import onnxruntime as ort # pyright: ignore[reportMissingImports]
            ort.preload_dlls()
        except Exception:
            pass

    @staticmethod
    def quiet_onnxruntime_logger(severity: int = DEFAULT_ORT_LOG_LEVEL) -> None:
        """Hide ONNX Runtime load-time chatter."""
        try:
            import onnxruntime as ort # pyright: ignore[reportMissingImports]
            ort.set_default_logger_severity(severity)
        except Exception:
            pass

    @classmethod
    def probe_cuda_functional(cls) -> bool:
        """
        Confirms whether CUDA runtime libraries actually load and execute inference
        by instantiating a GPU-configured RapidOCR instance and running a test
        inference on a minimal dummy image.
        """
        cls.register_nvidia_dll_directories()
        cls.quiet_onnxruntime_logger()
        try:
            from rapidocr_onnxruntime import RapidOCR # pyright: ignore[reportMissingImports]
            engine = RapidOCR(
                det_use_cuda=True, det_model_path=None,
                cls_use_cuda=True, cls_model_path=None,
                rec_use_cuda=True, rec_model_path=None,
            )
            # Run test inference to verify cuDNN dynamic loading (e.g. cudnn64_9.dll)
            dummy_image = np.zeros((64, 64, 3), dtype=np.uint8)
            engine(dummy_image)
            return True
        except Exception as exc:
            logger.debug("CUDA functional probe encountered exception: %s", exc)
            return False

    @classmethod
    def detect_gpu_support(cls) -> bool:
        """
        Checks whether onnxruntime has a functioning GPU execution provider.
        Returns True if OCR can execute on GPU, False if CPU only.
        """
        cls.register_nvidia_dll_directories()
        try:
            import onnxruntime as ort # pyright: ignore[reportMissingImports]
        except ImportError:
            logger.info("onnxruntime is not installed. OCR will run on CPU only.")
            return False

        try:
            providers = ort.get_available_providers()
            device = ort.get_device()
        except Exception as exc:
            logger.debug("Error querying onnxruntime device: %s", exc)
            providers, device = [], "CPU"

        if not ("CUDAExecutionProvider" in providers and device == "GPU"):
            logger.info("No GPU execution provider detected. OCR will run on CPU only.")
            logger.info("onnxruntime providers found: %s", ", ".join(providers) or "none")
            logger.info("To enable GPU acceleration: pip install onnxruntime-gpu")
            return False

        if cls.probe_cuda_functional():
            logger.info("GPU acceleration confirmed working (CUDAExecutionProvider).")
            return True

        logger.info("NOTE: onnxruntime-gpu is installed but CUDA/cuDNN execution failed during validation.")
        logger.info("      cuDNN runtime library (e.g. cudnn64_9.dll) is missing or mismatched.")
        logger.info("      To enable GPU acceleration on NVIDIA RTX cards, install cuDNN via:")
        logger.info("        .\\.venv\\Scripts\\python.exe -m pip install nvidia-cudnn-cu12")
        logger.info("      OCR will run on CPU only.")
        return False


# --------------------------------------------------------------------------- #
# Path Manager
# --------------------------------------------------------------------------- #

class PathManager:
    """Manages file discovery and output path calculation without collisions."""

    def __init__(self, source_dir: Path, target_dir: Optional[Path] = None, recursive: bool = False):
        self.source_dir = source_dir.resolve()
        base_target = target_dir.resolve() if target_dir else self.source_dir
        self.clear_text_dir = base_target / OUTPUT_DIR_NAME
        self.recursive = recursive

    def discover_pdfs(self) -> List[Path]:
        """Discovers all PDF files under the source directory."""
        if not self.source_dir.is_dir():
            raise FileNotFoundError(
                format_actionable_error(
                    context="PDF Discovery",
                    reason=f"Source directory '{self.source_dir}' does not exist or is not a directory.",
                    action="Verify the directory path is spelled correctly, the drive is mounted, and read permissions are granted.",
                )
            )

        if self.recursive:
            return sorted(
                p.resolve() for p in self.source_dir.rglob(f"*{SUPPORTED_EXTENSION}")
                if p.is_file() and p.suffix.lower() == SUPPORTED_EXTENSION
            )
        return sorted(
            p.resolve() for p in self.source_dir.iterdir()
            if p.is_file() and p.suffix.lower() == SUPPORTED_EXTENSION
        )

    def resolve_output_path(self, pdf_path: Path) -> Path:
        """
        Calculates output destination path. When recursive is enabled, replicates
        the relative subdirectory structure to prevent collisions.
        """
        resolved_pdf = pdf_path.resolve()
        if self.recursive:
            try:
                rel_path = resolved_pdf.relative_to(self.source_dir)
                return self.clear_text_dir / rel_path.with_suffix(OUTPUT_EXTENSION)
            except ValueError:
                pass
        return self.clear_text_dir / f"{resolved_pdf.stem}{OUTPUT_EXTENSION}"


# --------------------------------------------------------------------------- #
# Page Classifier
# --------------------------------------------------------------------------- #

class PageClassifier:
    """Inspects PDF pages to classify them as digital text, scanned image, or empty."""

    def __init__(self, text_threshold: int = DEFAULT_TEXT_THRESHOLD):
        self.text_threshold = text_threshold

    def classify_page(self, page: Any, page_num: int) -> PageClassification:
        """Classifies a single pypdf PageObject."""
        try:
            extracted_text = (page.extract_text() or "").strip()
            if len(extracted_text) >= self.text_threshold:
                return PageClassification(
                    page_num=page_num,
                    page_type=PageType.TEXT,
                    content=extracted_text,
                )

            # Check if page contains extractable images
            images = getattr(page, "images", [])
            if len(images) > 0:
                # Page requires OCR on the embedded scan image
                return PageClassification(
                    page_num=page_num,
                    page_type=PageType.OCR,
                    content="",
                    image_index=0,
                )

            # Neither text nor images found
            return PageClassification(
                page_num=page_num,
                page_type=PageType.EMPTY,
                content="",
            )
        except Exception as exc:
            return PageClassification(
                page_num=page_num,
                page_type=PageType.ERROR,
                content=format_actionable_error(
                    context=f"Page Classification (page {page_num})",
                    reason=f"Failed to inspect page content ({exc}).",
                    action="Check if the PDF is encrypted, password-protected, or has corrupt internal streams.",
                ),
            )


# --------------------------------------------------------------------------- #
# OCR Worker & Engine
# --------------------------------------------------------------------------- #

_worker_engine: Any = None
_worker_max_dimension: Optional[int] = None
_worker_use_gpu: bool = False


def init_ocr_worker(use_gpu: bool, max_dimension: Optional[int] = None) -> None:
    """Initializes the worker process OCR engine and settings."""
    global _worker_engine, _worker_max_dimension, _worker_use_gpu
    _worker_max_dimension = max_dimension
    _worker_use_gpu = False

    GpuCapabilityDetector.register_nvidia_dll_directories()
    from rapidocr_onnxruntime import RapidOCR # pyright: ignore[reportMissingImports]
    if use_gpu:
        GpuCapabilityDetector.quiet_onnxruntime_logger()
        try:
            engine = RapidOCR(
                det_use_cuda=True, det_model_path=None,
                cls_use_cuda=True, cls_model_path=None,
                rec_use_cuda=True, rec_model_path=None,
            )
            dummy_image = np.zeros((64, 64, 3), dtype=np.uint8)
            engine(dummy_image)
            _worker_engine = engine
            _worker_use_gpu = True
            return
        except Exception as exc:
            logger.warning("Worker failed GPU inference check (%s); falling back to CPU.", exc)

    _worker_engine = RapidOCR()
    _worker_use_gpu = False


def ocr_page_task(task: OcrTask) -> OcrResult:
    """
    Executes OCR for a single page in a worker process.
    Loads and extracts the image on demand, avoiding unbounded RAM allocation.
    """
    global _worker_engine, _worker_max_dimension, _worker_use_gpu
    pdf_path, page_num, total_pages, img_idx = task

    try:
        reader = PdfReader(pdf_path)
        page = reader.pages[page_num - 1]
        images = getattr(page, "images", [])
        if not images or img_idx >= len(images):
            return OcrResult(
                pdf_path=pdf_path,
                page_num=page_num,
                text="",
                error=format_actionable_error(
                    context=f"OCR Image Extraction ({Path(pdf_path).name}:p{page_num})",
                    reason=f"No raster image found at index {img_idx}.",
                    action="Check if the page contains vector paths or text rather than scanned images.",
                ),
            )

        img_data = images[img_idx].data
        image = Image.open(io.BytesIO(img_data)).convert("RGB")
        width, height = image.size

        if _worker_max_dimension and _worker_max_dimension > 0:
            scale = min(1.0, float(_worker_max_dimension) / max(width, height))
            if scale < 1.0:
                image = image.resize(
                    (int(width * scale), int(height * scale)),
                    Image.Resampling.BILINEAR,
                )

        image_array = np.array(image)
        try:
            ocr_result, _ = _worker_engine(image_array)
        except Exception as exc:
            if _worker_use_gpu:
                logger.warning(
                    "Worker GPU inference failed on page %d of %s (%s); falling back to CPU.",
                    page_num, Path(pdf_path).name, exc,
                )
                from rapidocr_onnxruntime import RapidOCR # pyright: ignore[reportMissingImports]
                _worker_engine = RapidOCR()
                _worker_use_gpu = False
                ocr_result, _ = _worker_engine(image_array)
            else:
                raise

        # Preserve linebreaks by joining recognized lines with newline
        extracted_lines = [r[1] for r in ocr_result] if ocr_result else []
        page_text = "\n".join(extracted_lines)

        return OcrResult(
            pdf_path=pdf_path,
            page_num=page_num,
            text=page_text,
            error=None,
            used_gpu=_worker_use_gpu,
        )
    except Exception as exc:
        return OcrResult(
            pdf_path=pdf_path,
            page_num=page_num,
            text="",
            error=format_actionable_error(
                context=f"OCR Task ({Path(pdf_path).name}:p{page_num})",
                reason=f"OCR inference failed ({exc}).",
                action="Verify image integrity and check system memory availability.",
            ),
            used_gpu=_worker_use_gpu,
        )


# --------------------------------------------------------------------------- #
# Pipeline Coordinator
# --------------------------------------------------------------------------- #

class PipelineCoordinator:
    """Orchestrates discovery, page classification, parallel OCR, and output assembly."""

    def __init__(self, config: PipelineConfig):
        self.config = config
        self.classifier = PageClassifier(text_threshold=config.text_threshold)

    @staticmethod
    def resolve_worker_count(requested_workers: Optional[int]) -> int:
        """Validates and determines the worker process count."""
        available_cores = cpu_count() or 1
        if requested_workers is not None:
            if requested_workers < 1:
                raise ValueError(
                    format_actionable_error(
                        context="Configuration: --workers",
                        reason=f"Worker count must be at least 1 (received {requested_workers}).",
                        action=f"Specify a worker count between 1 and {available_cores} (default: {DEFAULT_WORKERS}).",
                    )
                )
            if requested_workers > available_cores:
                logger.warning(
                    format_actionable_error(
                        context="Configuration: --workers",
                        reason=f"Requested worker count ({requested_workers}) exceeds {available_cores} logical CPU cores.",
                        action="High worker counts may cause thread thrashing; consider lowering --workers.",
                    )
                )
            return requested_workers
        return DEFAULT_WORKERS

    def _classify_document(self, pdf_path: Path) -> DocumentClassificationPlan:
        """
        Inspects all pages in a single PDF document and returns a plan containing
        digital texts, OCR tasks, and any page-level errors without mutating external state.
        """
        try:
            reader = PdfReader(str(pdf_path))
            total_pages = len(reader.pages)
            digital_pages: Dict[int, str] = {}
            ocr_tasks: List[OcrTask] = []
            errors: List[str] = []

            for idx, page in enumerate(reader.pages):
                page_num = idx + 1
                classification = self.classifier.classify_page(page, page_num)

                if classification.page_type == PageType.TEXT:
                    digital_pages[page_num] = classification.content
                elif classification.page_type == PageType.OCR:
                    ocr_tasks.append(OcrTask(
                        pdf_path=str(pdf_path),
                        page_num=page_num,
                        total_pages=total_pages,
                        image_index=classification.image_index,
                    ))
                elif classification.page_type == PageType.EMPTY:
                    digital_pages[page_num] = ""
                else:
                    errors.append(classification.content)
                    digital_pages[page_num] = ""

            return DocumentClassificationPlan(
                pdf_path=pdf_path,
                total_pages=total_pages,
                digital_pages=digital_pages,
                ocr_tasks=ocr_tasks,
                errors=errors,
            )
        except Exception as exc:
            err_msg = format_actionable_error(
                context=f"Read PDF ({pdf_path.name})",
                reason=f"Failed to open or parse document structure ({exc}).",
                action="Verify that the PDF file is not corrupt, encrypted, or password-protected.",
            )
            return DocumentClassificationPlan(
                pdf_path=pdf_path,
                total_pages=0,
                digital_pages={},
                ocr_tasks=[],
                errors=[err_msg],
            )

    def run(self) -> int:
        """Executes the full extraction pipeline. Returns exit code (0 for success)."""
        use_gpu = GpuCapabilityDetector.detect_gpu_support()
        if self.config.check_gpu:
            return 0

        if not self.config.source_dir:
            logger.error(
                format_actionable_error(
                    context="CLI Arguments",
                    reason="No source directory provided.",
                    action="Provide a path to a directory containing PDFs (e.g. 'python pdfToText.py <DIR>'), or use '--check-gpu'.",
                )
            )
            return 1

        path_manager = PathManager(
            source_dir=self.config.source_dir,
            target_dir=self.config.target_dir,
            recursive=self.config.recursive,
        )

        try:
            pdf_files = path_manager.discover_pdfs()
        except Exception as exc:
            logger.error(
                format_actionable_error(
                    context="PDF Discovery",
                    reason=f"Failed reading directory '{path_manager.source_dir}' ({exc}).",
                    action="Verify the directory path exists and user read permissions are granted.",
                )
            )
            return 1

        logger.info("Source directory: %s", path_manager.source_dir)
        logger.info("Output directory: %s", path_manager.clear_text_dir)
        logger.info("Workers: %d", self.config.workers)
        logger.info("Discovered %d PDF file(s).", len(pdf_files))

        if not pdf_files:
            logger.info("No PDF files to process.")
            return 0

        if not self.config.dry_run:
            path_manager.clear_text_dir.mkdir(parents=True, exist_ok=True)

        # Document page mapping: {pdf_path: {page_num: text}}
        document_pages: Dict[str, Dict[int, str]] = {}
        document_total_pages: Dict[str, int] = {}
        ocr_tasks: List[OcrTask] = []
        skipped_files: List[Tuple[Path, str]] = []
        processing_errors: List[str] = []

        logger.info("Reviewing and classifying PDF pages...")
        for pdf_path in pdf_files:
            out_path = path_manager.resolve_output_path(pdf_path)
            if not self.config.overwrite and out_path.exists():
                skipped_files.append((pdf_path, f"Output already exists at '{out_path.name}'"))
                continue

            plan = self._classify_document(pdf_path)
            if plan.errors:
                processing_errors.extend(plan.errors)

            if plan.total_pages > 0:
                document_total_pages[str(pdf_path)] = plan.total_pages
                document_pages[str(pdf_path)] = plan.digital_pages
                ocr_tasks.extend(plan.ocr_tasks)

        total_ocr_pages = len(ocr_tasks)
        active_files = len(document_pages)
        logger.info(
            "Classification summary: %d file(s) queued (%d page(s) require OCR), %d skipped, %d read error(s).",
            active_files, total_ocr_pages, len(skipped_files), len(processing_errors),
        )

        if self.config.dry_run:
            logger.info("Dry-run enabled: No OCR executed and no output files written.")
            return 0

        # Execute OCR tasks in parallel
        if ocr_tasks:
            logger.info("Starting OCR across %d worker process(es) for %d page(s)...", self.config.workers, total_ocr_pages)
            start_time = time.time()

            gpu_pages = 0
            cpu_pages = 0
            with Pool(
                processes=self.config.workers,
                initializer=init_ocr_worker,
                initargs=(use_gpu, self.config.max_dimension),
            ) as pool:
                chunk_size = min(DEFAULT_CHUNK_SIZE, max(1, total_ocr_pages // self.config.workers)) if self.config.workers > 0 else 1
                for idx, result in enumerate(pool.imap_unordered(ocr_page_task, ocr_tasks, chunksize=chunk_size)):
                    if result.error:
                        processing_errors.append(result.error)
                        logger.warning(result.error)

                    document_pages[result.pdf_path][result.page_num] = result.text
                    if result.used_gpu:
                        gpu_pages += 1
                    else:
                        cpu_pages += 1

                    progress = idx + 1
                    if progress % 25 == 0 or progress == total_ocr_pages:
                        elapsed = time.time() - start_time
                        logger.info("OCR progress: %d/%d pages (%.1fs elapsed)", progress, total_ocr_pages, elapsed)

            logger.info("OCR completed in %.1fs.", time.time() - start_time)
            if use_gpu:
                logger.info("Pages OCR'd on GPU: %d, fell back to CPU: %d.", gpu_pages, cpu_pages)

        # Assemble and write final document text files
        written_count = 0
        for pdf_path_str, pages in document_pages.items():
            pdf_path = Path(pdf_path_str)
            out_path = path_manager.resolve_output_path(pdf_path)
            out_path.parent.mkdir(parents=True, exist_ok=True)

            ordered_texts = [
                pages.get(p_num, "")
                for p_num in range(1, document_total_pages.get(pdf_path_str, len(pages)) + 1)
            ]
            full_document_text = "\n\n".join(t for t in ordered_texts if t.strip())

            try:
                out_path.write_text(full_document_text, encoding="utf-8")
                written_count += 1
            except Exception as exc:
                write_err = format_actionable_error(
                    context=f"Output Writing ({out_path.name})",
                    reason=f"Failed to write text file to '{out_path}' ({exc}).",
                    action="Check destination directory permissions and available disk space.",
                )
                processing_errors.append(write_err)
                logger.error(write_err)

        logger.info("Pipeline run finished. Wrote %d text file(s) to %s.", written_count, path_manager.clear_text_dir)
        if processing_errors:
            logger.error(
                "Execution FAILED with %d error(s). Review detailed failure breakdown below:",
                len(processing_errors),
            )
            for idx, error_msg in enumerate(processing_errors, 1):
                logger.error("  [%d] %s", idx, error_msg)
            return 1

        return 0


# --------------------------------------------------------------------------- #
# CLI Parser & Entrypoint
# --------------------------------------------------------------------------- #

def parse_arguments(argv: Optional[List[str]] = None) -> argparse.Namespace:
    """Configures and parses command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Review PDFs, extract text layers directly, OCR scanned pages, "
                    "and assemble results into clear-text files."
    )
    parser.add_argument(
        "source", nargs="?", default=None,
        help="Directory containing PDF files to review (not required with --check-gpu)",
    )
    parser.add_argument(
        "--target", "-t", default=None,
        help="Directory in which the 'clear-text' output folder is created (default: same as source)",
    )
    parser.add_argument(
        "--check-gpu", action="store_true",
        help="Check GPU/CUDA support, print diagnostics, and exit. If you want to enable GPU acceleration, you can install the matching cuDNN package into the virtual environment via pip install nvidia-cudnn-cu12 if you have an NVIDIA GPU. See https://pypi.org/project/nvidia-pip-cudnn/ for details.",
    )
    parser.add_argument(
        "--workers", "-w", type=int, default=DEFAULT_WORKERS,
        help=f"Number of worker processes to use for OCR (default: {DEFAULT_WORKERS}). Tip: On CPU with 16 logical cores, you can comfortably set -w 4 or -w 6 for faster processing.",
    )
    parser.add_argument(
        "--text-threshold", type=int, default=DEFAULT_TEXT_THRESHOLD,
        help=f"Minimum extractable characters for a page to be classified as text (default: {DEFAULT_TEXT_THRESHOLD})",
    )
    parser.add_argument(
        "--max-dimension", type=int, default=None,
        help="Optional maximum image dimension (width/height) to downscale OCR images for performance",
    )
    parser.add_argument(
        "--recursive", "-r", action="store_true",
        help="Recursively process subdirectories and mirror structure in clear-text",
    )
    parser.add_argument(
        "--overwrite", action="store_true",
        help="Overwrite existing .txt files in clear-text (default: skip converted files)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Classify and report without running OCR or writing output files",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Enable detailed debug logging",
    )
    return parser.parse_args(argv)


def configure_logging(verbose: bool = False) -> None:
    """Configures structured application logging."""
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )


def main(argv: Optional[List[str]] = None) -> int:
    """Application entrypoint."""
    args = parse_arguments(argv)
    configure_logging(args.verbose)

    try:
        workers = PipelineCoordinator.resolve_worker_count(args.workers)
    except ValueError as exc:
        logger.error("%s", exc)
        return 1

    config = PipelineConfig(
        source_dir=Path(args.source) if args.source else None,
        target_dir=Path(args.target) if args.target else None,
        workers=workers,
        text_threshold=args.text_threshold,
        max_dimension=args.max_dimension,
        recursive=args.recursive,
        overwrite=args.overwrite,
        dry_run=args.dry_run,
        check_gpu=args.check_gpu,
        verbose=args.verbose,
    )

    coordinator = PipelineCoordinator(config)
    return coordinator.run()


if __name__ == "__main__":
    sys.exit(main())
