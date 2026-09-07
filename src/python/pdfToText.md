# Walkthrough r3

**Date:** 2026-09-07  
**Request:** Align `pdfToText.py` error handling and messaging with updated Team-Code engineering standards.  
**Constraints:** Default engineering standards: clear/actionable error messages with context, no nested loops, pure functions without mixed side effects, errors surfacing at boundaries, strict failure exit code.

## Phase notes

- **Architect & Principal Dev:** 
  - Standardized error reporting with `format_actionable_error(context, reason, action)` across the codebase.
  - Eliminated the nested loop in `PipelineCoordinator.run()` by extracting `_classify_document(pdf_path: Path) -> DocumentClassificationPlan`, which inspects a single document and returns an immutable plan without mutating external state.
  - Enforced full batch failure (exit code 1) on any processing error, per user directive, with a detailed categorized failure breakdown in logging to expedite debugging.
- **Senior Dev:**
  - Enriched error messages across `PathManager`, `PageClassifier`, `ocr_page_task`, `PipelineCoordinator.resolve_worker_count`, and `PipelineCoordinator.run`.
  - Ensured no sensitive data (such as binary blobs or environment secrets) are exposed in error logs.
- **QA:**
  - Expanded unit test suite from 11 to 14 tests: added tests for actionable error formatting structure, page classification error actionability, pure document classification plan generation, and full failure exit code handling.
- **CI/CD:**
  - Ran full test suite via virtual environment Python runner: 14/14 tests pass. Verified CLI error reporting for invalid `--workers`, missing source directory, and non-existent paths.

## Commands and results

```powershell
& ".venv\Scripts\python.exe" ".\src\python\tests\test_pdf_to_text.py" -v
test_format_actionable_error_structure (__main__.TestActionableErrorFormatting.test_format_actionable_error_structure) ... ok
test_page_classifier_error_is_actionable (__main__.TestActionableErrorFormatting.test_page_classifier_error_is_actionable) ... ok
test_classify_document_pure_function (__main__.TestDocumentClassificationPlan.test_classify_document_pure_function) ... ok
test_run_returns_failure_code_on_errors (__main__.TestFailureExitCode.test_run_returns_failure_code_on_errors) ... ok
test_mixed_page_assembly_order (__main__.TestHybridDocumentAssembly.test_mixed_page_assembly_order) ... ok
test_classify_empty_page (__main__.TestPageClassifier.test_classify_empty_page) ... ok
test_classify_ocr_page_when_text_below_threshold_and_has_images (__main__.TestPageClassifier.test_classify_ocr_page_when_text_below_threshold_and_has_images) ... ok
test_classify_text_page (__main__.TestPageClassifier.test_classify_text_page) ... ok
test_discover_pdfs (__main__.TestPathManager.test_discover_pdfs) ... ok
test_resolve_output_path_non_recursive (__main__.TestPathManager.test_resolve_output_path_non_recursive) ... ok
test_resolve_output_path_recursive_preserves_subdirectories (__main__.TestPathManager.test_resolve_output_path_recursive_preserves_subdirectories) ... ok
test_custom_worker_count (__main__.TestWorkerConfiguration.test_custom_worker_count) ... ok
test_default_worker_is_one (__main__.TestWorkerConfiguration.test_default_worker_is_one) ... ok
test_invalid_worker_count_raises_value_error (__main__.TestWorkerConfiguration.test_invalid_worker_count_raises_value_error) ... ok

----------------------------------------------------------------------
Ran 14 tests in 0.798s

OK
```

```powershell
& ".venv\Scripts\python.exe" ".\src\python\pdfToText.py" . -w 0
09:59:56 [ERROR] [Configuration: --workers] Worker count must be at least 1 (received 0). Action: Specify a worker count between 1 and 32 (default: 1).
```

```powershell
& ".venv\Scripts\python.exe" ".\src\python\pdfToText.py"
10:00:06 [ERROR] [CLI Arguments] No source directory provided. Action: Provide a path to a directory containing PDFs (e.g. 'python pdfToText.py <DIR>'), or use '--check-gpu'.
```

## End-user feedback

User specified that the script should return full failure (`exit code 1`) on any error and error logs must provide enough details to debug the problem. Both directives implemented and tested.

## Changes to the original request

None.

