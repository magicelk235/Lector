#pragma once

// ONNX Runtime's C API, made importable from Swift. The binary framework ships headers
// but no module map, so this target supplies one.
#include <onnxruntime/onnxruntime_c_api.h>

/// The API function table for the ORT_API_VERSION these headers declare, or NULL if the
/// linked library is older than that.
const OrtApi *_Nullable HLOrtApi(void);
