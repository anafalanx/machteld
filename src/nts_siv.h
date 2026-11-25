/* RFC 5297 interface adapted from Lunar src/siv.h, MIT, licenses/Lunar-MIT.txt. */
#ifndef MACHTELD_NTS_SIV_H
#define MACHTELD_NTS_SIV_H
#include <stddef.h>
#include <stdint.h>
typedef struct {const uint8_t *p; size_t n;} SivSlice;
int Siv_Encrypt(const uint8_t key[32], const SivSlice *ad, size_t nad,
                const uint8_t *pt, size_t n, uint8_t *out);
int Siv_Decrypt(const uint8_t key[32], const SivSlice *ad, size_t nad,
                const uint8_t *ct, size_t n, uint8_t *out);
#endif
