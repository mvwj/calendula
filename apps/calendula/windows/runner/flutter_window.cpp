#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool show_on_first_frame)
    : project_(project), show_on_first_frame_(show_on_first_frame) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  desktop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "app.calendula/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    const wchar_t* path = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    if (call.method_name() == "startupStatus") {
      DWORD size = 0;
      const auto status = RegGetValueW(HKEY_CURRENT_USER, path, L"Calendula", RRF_RT_REG_SZ, nullptr, nullptr, &size);
      result->Success(flutter::EncodableValue(status == ERROR_SUCCESS));
    } else if (call.method_name() == "startup") {
      const auto enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!enabled) { result->Error("ARGUMENT", "Expected a startup preference."); return; }
      HKEY key = nullptr;
      if (RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
        result->Error("STARTUP", "Startup setting could not be opened."); return;
      }
      LSTATUS status;
      if (*enabled) {
        wchar_t executable[32768]{};
        GetModuleFileNameW(nullptr, executable, 32768);
        const std::wstring command = L"\"" + std::wstring(executable) + L"\" --autostart";
        status = RegSetValueExW(key, L"Calendula", 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
      } else { status = RegDeleteValueW(key, L"Calendula"); }
      RegCloseKey(key);
      if (status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND) result->Success();
      else result->Error("STARTUP", "Startup preference could not be saved.");
    } else { result->NotImplemented(); }
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (show_on_first_frame_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  desktop_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
