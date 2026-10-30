#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool widget = std::find(command_line_arguments.begin(), command_line_arguments.end(), "--widget") != command_line_arguments.end();
  const bool checking = std::find(command_line_arguments.begin(), command_line_arguments.end(), "--self-check") != command_line_arguments.end() ||
      std::find(command_line_arguments.begin(), command_line_arguments.end(), "--sync-device-check") != command_line_arguments.end() ||
      std::find(command_line_arguments.begin(), command_line_arguments.end(), "--cloud-sync-check") != command_line_arguments.end() ||
      std::find(command_line_arguments.begin(), command_line_arguments.end(), "--journey-check") != command_line_arguments.end() ||
      std::find(command_line_arguments.begin(), command_line_arguments.end(), "--mail-transport-check") != command_line_arguments.end();
  const bool autostart = std::find(command_line_arguments.begin(), command_line_arguments.end(), "--autostart") != command_line_arguments.end();
  HANDLE instance_mutex = checking ? nullptr : CreateMutexW(nullptr, FALSE, widget ? L"Local\\CalendulaAgenda" : L"Local\\CalendulaMain");
  if (!checking && GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = FindWindowW(nullptr, widget ? L"Calendula · Today" : L"Calendula");
    if (existing) { ShowWindow(existing, SW_RESTORE); SetForegroundWindow(existing); }
    if (instance_mutex) CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, !checking && !autostart);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(widget ? L"Calendula · Today" : L"Calendula", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex) CloseHandle(instance_mutex);
  return EXIT_SUCCESS;
}
