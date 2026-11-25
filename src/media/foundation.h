#ifndef MACHTELD_MEDIA_FOUNDATION_H
#define MACHTELD_MEDIA_FOUNDATION_H
#include "rae_common.h"
#include <mfapi.h>
/* Resolve the optional Windows Media Foundation runtime only for AAC. The
 * host remains usable on Windows editions without the Media Feature Pack. */
HRESULT media_foundation_start(void);
void media_foundation_stop(void);
HRESULT media_sample(IMFSample **sample);
HRESULT media_type(IMFMediaType **type);
HRESULT media_buffer(DWORD count, IMFMediaBuffer **buffer);
HRESULT media_aligned_buffer(DWORD count, DWORD alignment, IMFMediaBuffer **buffer);
#endif
