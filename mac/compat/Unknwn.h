// Minimal IUnknown so DirectX-only branches of shared add-on code compile; never instantiated on macOS.
#pragma once
struct IUnknown { virtual unsigned long AddRef() = 0; virtual unsigned long Release() = 0; };
