#ifndef CALENDULA_STRING_CONVERSION_H
#define CALENDULA_STRING_CONVERSION_H
#include <windows.h>
#include <string>
// Preserve ATL's default Windows code-page conversion at credential boundaries.
// Encryption and storage code are unchanged. Removes an optional ATL dependency.
class CA2W {
 public:
  wchar_t* m_psz = nullptr;
  explicit CA2W(const char* value) {
    const int length = MultiByteToWideChar(CP_ACP, 0, value, -1, nullptr, 0);
    if (length > 0) {
      value_.resize(length);
      MultiByteToWideChar(CP_ACP, 0, value, -1, value_.data(), length);
      m_psz = value_.data();
    }
  }
  operator const wchar_t*() const { return value_.c_str(); }
 private:
  std::wstring value_;
};
class CW2A {
 public:
  explicit CW2A(const wchar_t* value) {
    const int length = WideCharToMultiByte(CP_ACP, 0, value, -1, nullptr, 0, nullptr, nullptr);
    if (length > 0) {
      value_.resize(length);
      WideCharToMultiByte(CP_ACP, 0, value, -1, value_.data(), length, nullptr, nullptr);
    }
  }
  operator const char*() const { return value_.c_str(); }
 private:
  std::string value_;
};
#endif
