#ifndef RUNNER_PDF_RENDER_H_
#define RUNNER_PDF_RENDER_H_

#include <cstdint>
#include <string>
#include <vector>

struct PdfPageImage {
  bool ok = false;
  int pages = 0;
  std::vector<uint8_t> png;
  std::wstring error;
};

// Blocks while Windows.Data.Pdf works, so call it away from the platform thread.
PdfPageImage RenderPdfPage(const std::wstring& path, int page, unsigned width);

#endif  // RUNNER_PDF_RENDER_H_
