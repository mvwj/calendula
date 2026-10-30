Based on flutter_secure_storage_windows 4.2.2, MIT license (LICENSE included).
Local change: replace ATL CA2W / CW2A string conversion with a small standard
C++/Win32 equivalent using the same Windows code page. Credential operations,
encryption and persisted data formats are unchanged. This allows compilation
with the installed MSVC SDK without requiring the optional ATL component.
Source: https://github.com/juliansteenbakker/flutter_secure_storage
