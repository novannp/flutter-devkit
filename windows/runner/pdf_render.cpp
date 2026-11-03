#include "pdf_render.h"

#include <winrt/Windows.Data.Pdf.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Storage.h>

#include <algorithm>

using namespace winrt::Windows::Data::Pdf;
using namespace winrt::Windows::Storage;
using namespace winrt::Windows::Storage::Streams;

PdfPageImage RenderPdfPage(const std::wstring& path, int page, unsigned width) {
  PdfPageImage out;
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    auto document = PdfDocument::LoadFromFileAsync(StorageFile::GetFileFromPathAsync(path).get()).get();
    out.pages = static_cast<int>(document.PageCount());
    if (out.pages == 0) {
      out.error = L"This PDF has no pages.";
      return out;
    }
    auto pdf_page = document.GetPage(static_cast<uint32_t>(std::clamp(page, 0, out.pages - 1)));
    PdfPageRenderOptions options;
    options.DestinationWidth(width);
    InMemoryRandomAccessStream stream;
    pdf_page.RenderToStreamAsync(stream, options).get();
    pdf_page.Close();

    DataReader reader(stream.GetInputStreamAt(0));
    auto size = static_cast<uint32_t>(stream.Size());
    reader.LoadAsync(size).get();
    out.png.resize(size);
    reader.ReadBytes(out.png);
    out.ok = true;
  } catch (const winrt::hresult_error& e) {
    out.error = e.message().c_str();
  }
  return out;
}
