#include "COnnxRuntime.h"

const OrtApi *HLOrtApi(void) {
    return OrtGetApiBase()->GetApi(ORT_API_VERSION);
}
