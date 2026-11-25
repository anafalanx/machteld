/* Windows media and audio GUID definitions. Adapted from Rae (MIT), see licenses/rae.txt. */
#define INITGUID
#define COBJMACROS
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <initguid.h>

#include <mmdeviceapi.h>    /* CLSID_MMDeviceEnumerator, IID_IMMDeviceEnumerator */
#include <audioclient.h>    /* IID_IAudioClient, IID_IAudioRenderClient          */
#include <mfapi.h>          /* MF_MT_* attribute GUIDs, MFMediaType_Audio,
                               MFAudioFormat_AAC / _Float / _PCM                 */
#include <mftransform.h>    /* IID_IMFTransform                                  */
#include <mferror.h>

/* The system AAC decoder MFT.  mingw-w64 usually ships <wmcodecdsp.h>; when
 * it does not, define the CLSID by value (the contract in rae_aac.h).       */
#if __has_include(<wmcodecdsp.h>)
#include <wmcodecdsp.h>
#else
DEFINE_GUID(CLSID_CMSAACDecMFT,
            0x32d186a7, 0x218f, 0x4c75,
            0x88, 0x76, 0xdd, 0x77, 0x27, 0x3a, 0x89, 0x99);
#endif
