#!/usr/bin/env python3
"""
Convert a PDF to UTF-8 plain text (macOS-friendly, pure Python).

Usage:
  python3 pdf_to_txt.py /path/to/Distributed_System__Lab_2.pdf

Output:
  /path/to/Distributed_System__Lab_2.pdf.txt (next to the input file)

Dependencies:
  - pdfminer.six (recommended)
      pip install pdfminer.six
  - Optional fallback: PyPDF2
      pip install PyPDF2

Notes:
  - For scanned/image-only PDFs, the output may be empty. In that case run OCR to
    create a searchable PDF first (e.g., using `ocrmypdf`) and then run this script again.
"""

import argparse
import sys
import os

# Try to import pdfminer first
try:
    from pdfminer.high_level import extract_text  # type: ignore
    HAVE_PDFMINER = True
except Exception:
    HAVE_PDFMINER = False

# Optional fallback to PyPDF2
try:
    from PyPDF2 import PdfReader  # type: ignore
    HAVE_PYPDF2 = True
except Exception:
    HAVE_PYPDF2 = False


def pdf_to_text_pdfminer(in_path: str) -> str:
    return extract_text(in_path) or ""


def pdf_to_text_pypdf2(in_path: str) -> str:
    reader = PdfReader(in_path)
    texts = []
    for page in reader.pages:
        try:
            texts.append(page.extract_text() or "")
        except Exception:
            texts.append("")
    return "\n".join(texts)


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert PDF to UTF-8 text")
    parser.add_argument("pdf", help="Input PDF file path")
    args = parser.parse_args()

    in_path = args.pdf
    if not os.path.isfile(in_path):
        print(f"Error: file not found: {in_path}", file=sys.stderr)
        return 1

    out_path = in_path + ".txt"

    text = ""

    if HAVE_PDFMINER:
        try:
            text = pdf_to_text_pdfminer(in_path)
        except Exception as e:
            print(f"Warning: pdfminer failed: {e}", file=sys.stderr)
    else:
        print("Warning: pdfminer.six not installed; trying PyPDF2 fallback.", file=sys.stderr)

    if not text and HAVE_PYPDF2:
        try:
            text = pdf_to_text_pypdf2(in_path)
        except Exception as e:
            print(f"Warning: PyPDF2 failed: {e}", file=sys.stderr)

    if not text:
        print("Warning: extracted text is empty. The PDF may be scanned (image-based).", file=sys.stderr)
        print("Tip: Install OCRmyPDF and run: ocrmypdf <in.pdf> <out_searchable.pdf> then re-run this script.", file=sys.stderr)

    # Normalize newlines and ensure UTF-8
    text = text.replace('\r\n', '\n').replace('\r', '\n')

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(text)

    if os.path.getsize(out_path) > 0:
        print(f"OK: wrote {out_path}")
        return 0
    else:
        print(f"Done, but output is empty: {out_path}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())



