/* RFC 5297 S2V/CTR adapted from Lunar src/siv.c. Copyright (c) 2026 the Time
 * Actual authors, MIT, see licenses/Lunar-MIT.txt. CNG owns AES and CMAC. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <string.h>
#include "nts_siv.h"

static void dbl(uint8_t x[16]) {
    uint8_t carry = x[0] >> 7;
    for (int i = 0; i < 15; ++i) x[i] = (uint8_t)((x[i] << 1) | (x[i+1] >> 7));
    x[15] = (uint8_t)((x[15] << 1) ^ (0x87 & -(int)carry));
}
static int cmac(BCRYPT_ALG_HANDLE alg, const uint8_t *key, const uint8_t *p, size_t n,
                const uint8_t *tail, size_t extra, uint8_t out[16]) {
    BCRYPT_HASH_HANDLE h = NULL;
    if (n > UINT32_MAX || BCryptCreateHash(alg, &h, NULL, 0, (PUCHAR)key, 16, 0) < 0) return -1;
    int ok = (!n || BCryptHashData(h, (PUCHAR)p, (ULONG)n, 0) >= 0) &&
             (!extra || BCryptHashData(h, (PUCHAR)tail, (ULONG)extra, 0) >= 0) &&
             BCryptFinishHash(h, out, 16, 0) >= 0;
    BCryptDestroyHash(h);
    return ok ? 0 : -1;
}
static int s2v(const uint8_t *key, const SivSlice *ad, size_t count, const uint8_t *p, size_t n, uint8_t tag[16]) {
    BCRYPT_ALG_HANDLE alg;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_AES_CMAC_ALGORITHM, NULL, 0) < 0) return -1;
    uint8_t d[16], m[16] = {0};
    int rc = cmac(alg, key, m, 16, NULL, 0, d);
    for (size_t i = 0; rc == 0 && i < count; ++i) {
        rc = cmac(alg, key, ad[i].p, ad[i].n, NULL, 0, m);
        if (rc) break;
        dbl(d);
        for (int j = 0; j < 16; ++j) d[j] ^= m[j];
    }
    if (!rc) {
        size_t head = 0;
        if (n < 16) {
            dbl(d);
            for (size_t i = 0; i < n; ++i) d[i] ^= p[i];
            d[n] ^= 0x80;
        } else {
            head = n - 16;
            for (size_t i = 0; i < 16; ++i) d[i] ^= p[head+i];
        }
        rc = cmac(alg, key, p, head, d, 16, tag);
    }
    SecureZeroMemory(d, sizeof d); SecureZeroMemory(m, sizeof m);
    BCryptCloseAlgorithmProvider(alg, 0);
    return rc;
}
static int ctr(const uint8_t *key, const uint8_t tag[16], const uint8_t *p, size_t n, uint8_t *out) {
    if (!n) return 0;
    BCRYPT_ALG_HANDLE alg; BCRYPT_KEY_HANDLE k = NULL;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_AES_ALGORITHM, NULL, 0) < 0) return -1;
    int ok = BCryptSetProperty(alg, BCRYPT_CHAINING_MODE, (PUCHAR)BCRYPT_CHAIN_MODE_ECB, sizeof BCRYPT_CHAIN_MODE_ECB, 0) >= 0 &&
             BCryptGenerateSymmetricKey(alg, &k, NULL, 0, (PUCHAR)key, 16, 0) >= 0;
    uint8_t counter[16], stream[16];
    memcpy(counter, tag, 16); counter[8] &= 0x7f; counter[12] &= 0x7f;
    for (size_t pos = 0; ok && pos < n;) {
        ULONG written;
        ok = BCryptEncrypt(k, counter, 16, NULL, NULL, 0, stream, 16, &written, 0) >= 0 && written == 16;
        if (!ok) break;
        for (int j = 0; j < 16 && pos < n; ++j, ++pos) out[pos] = p[pos] ^ stream[j];
        for (int j = 15; j >= 0; --j) if (++counter[j]) break;
    }
    SecureZeroMemory(counter, sizeof counter); SecureZeroMemory(stream, sizeof stream);
    if (k) BCryptDestroyKey(k);
    BCryptCloseAlgorithmProvider(alg, 0);
    return ok ? 0 : -1;
}
int Siv_Encrypt(const uint8_t key[32], const SivSlice *ad, size_t nad,
                const uint8_t *p, size_t n, uint8_t *out) {
    if (s2v(key, ad, nad, p, n, out)) return -1;
    return ctr(key + 16, out, p, n, out + 16);
}
int Siv_Decrypt(const uint8_t key[32], const SivSlice *ad, size_t nad,
                const uint8_t *ct, size_t n, uint8_t *out) {
    if (n < 16) return -1;
    n -= 16;
    uint8_t tag[16] = {0};
    int rc = ctr(key + 16, ct, ct + 16, n, out);
    if (!rc) rc = s2v(key, ad, nad, out, n, tag);
    volatile uint8_t different = 0;
    for (int i = 0; i < 16; ++i) different |= tag[i] ^ ct[i];
    SecureZeroMemory(tag, sizeof tag);
    if (rc || different) {SecureZeroMemory(out, n); return -1;}
    return 0;
}
