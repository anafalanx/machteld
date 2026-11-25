/* RFC 5297 vectors and boundary checks adapted from Lunar tests/test_core.c.
 * Copyright (c) 2026 the Time Actual authors. MIT, see licenses/Lunar-MIT.txt. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../src/nts_siv.h"
static int checks;
#define CHECK(x) do {++checks; if (!(x)) {fprintf(stderr,"failed at %d\n",__LINE__); exit(1);}} while (0)
#define CHECK_EQ_INT(x,y) CHECK((x)==(y))
static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static size_t unhex(const char *s, uint8_t *out, size_t cap) {
    size_t n = 0;
    while (*s) {
        if (*s == ' ' || *s == '\n') { s++; continue; }
        int hi = hex_nibble(s[0]);
        int lo = hex_nibble(s[1]);
        if (hi < 0 || lo < 0 || n >= cap) return 0;
        out[n++] = (uint8_t)((hi << 4) | lo);
        s += 2;
    }
    return n;
}
static int bufs_eq(const uint8_t *a, const uint8_t *b, size_t n) {
    for (size_t i = 0; i < n; i++) if (a[i] != b[i]) return 0;
    return 1;
}

static void test_siv_rfc5297_appendix_a1(void) {
    // RFC 5297 Appendix A.1: deterministic authenticated encryption
    // with a single associated-data element.
    //
    //   Key:        fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0
    //               f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff
    //   AD:         101112131415161718191a1b1c1d1e1f2021222324252627
    //   Plaintext:  112233445566778899aabbccddee
    //   V (tag):    85632d07c6e8f37f950acd320a2ecc93
    //   Cipher:     40c02b9690c4dc04daef7f6afe5c
    uint8_t key[32], ad[32], pt[32], want_tag[16], want_ct[32];
    size_t key_n = unhex("fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0"
                         "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff", key, sizeof key);
    size_t ad_n  = unhex("101112131415161718191a1b1c1d1e1f"
                         "2021222324252627", ad, sizeof ad);
    size_t pt_n  = unhex("112233445566778899aabbccddee", pt, sizeof pt);
    size_t tag_n = unhex("85632d07c6e8f37f950acd320a2ecc93",
                         want_tag, sizeof want_tag);
    size_t ct_n  = unhex("40c02b9690c4dc04daef7f6afe5c",
                         want_ct, sizeof want_ct);
    CHECK_EQ_INT(key_n, 32);
    CHECK_EQ_INT(ad_n, 24);
    CHECK_EQ_INT(pt_n, 14);
    CHECK_EQ_INT(tag_n, 16);
    CHECK_EQ_INT(ct_n, 14);

    SivSlice ad_vec = { ad, ad_n };
    uint8_t out[64];
    CHECK_EQ_INT(Siv_Encrypt(key, &ad_vec, 1, pt, pt_n, out), 0);
    CHECK(bufs_eq(out,        want_tag, 16));    // SIV matches RFC
    CHECK(bufs_eq(out + 16,   want_ct,  pt_n));  // CTR body matches RFC

    // Round-trip: the same AD + key must recover the plaintext exactly.
    uint8_t pt_back[32];
    CHECK_EQ_INT(Siv_Decrypt(key, &ad_vec, 1, out, 16 + pt_n, pt_back), 0);
    CHECK(bufs_eq(pt_back, pt, pt_n));
}

static void test_siv_rfc5297_appendix_a2(void) {
    // RFC 5297 Appendix A.2: multiple AD elements, longer plaintext
    // that spans three 16-byte S2V blocks (so the "xorend" path runs).
    //
    //   Key:        7f7e7d7c7b7a79787776757473727170
    //               404142434445464748494a4b4c4d4e4f
    //   AD1:        00112233445566778899aabbccddeeff
    //               deaddadadeaddadaffeeddccbbaa9988
    //               7766554433221100
    //   AD2:        102030405060708090a0
    //   Nonce:      09f911029d74e35bd84156c5635688c0
    //   Plaintext:  7468697320697320736f6d6520706c61
    //               696e7465787420746f20656e63727970
    //               74207573696e67205349562d414553
    //   V (tag):    7bdb6e3b432667eb06f4d14bff2fbd0f
    //   Cipher:     cb900f2fddbe404326601965c889bf17
    //               dba77ceb094fa663b7a3f748ba8af829
    //               ea64ad544a272e9c485b62a3fd5c0d
    uint8_t key[32], ad1[48], ad2[16], nonce[16], pt[64], want_tag[16], want_ct[64];
    size_t key_n = unhex("7f7e7d7c7b7a79787776757473727170"
                         "404142434445464748494a4b4c4d4e4f", key, sizeof key);
    size_t ad1_n = unhex("00112233445566778899aabbccddeeff"
                         "deaddadadeaddadaffeeddccbbaa9988"
                         "7766554433221100", ad1, sizeof ad1);
    size_t ad2_n = unhex("102030405060708090a0", ad2, sizeof ad2);
    size_t nc_n  = unhex("09f911029d74e35bd84156c5635688c0", nonce, sizeof nonce);
    size_t pt_n  = unhex("7468697320697320736f6d6520706c61"
                         "696e7465787420746f20656e63727970"
                         "74207573696e67205349562d414553", pt, sizeof pt);
    size_t tag_n = unhex("7bdb6e3b432667eb06f4d14bff2fbd0f", want_tag, sizeof want_tag);
    size_t ct_n  = unhex("cb900f2fddbe404326601965c889bf17"
                         "dba77ceb094fa663b7a3f748ba8af829"
                         "ea64ad544a272e9c485b62a3fd5c0d", want_ct, sizeof want_ct);
    CHECK_EQ_INT(key_n, 32);
    CHECK_EQ_INT(ad1_n, 40);
    CHECK_EQ_INT(ad2_n, 10);
    CHECK_EQ_INT(nc_n, 16);
    CHECK_EQ_INT(pt_n, 47);
    CHECK_EQ_INT(tag_n, 16);
    CHECK_EQ_INT(ct_n, 47);

    // Per RFC 5297 §2.6: the nonce is the LAST AD element.
    SivSlice ad_vec[3] = {
        { ad1,   ad1_n },
        { ad2,   ad2_n },
        { nonce, nc_n  },
    };
    uint8_t out[128];
    CHECK_EQ_INT(Siv_Encrypt(key, ad_vec, 3, pt, pt_n, out), 0);
    CHECK(bufs_eq(out,      want_tag, 16));
    CHECK(bufs_eq(out + 16, want_ct,  pt_n));

    uint8_t pt_back[64];
    CHECK_EQ_INT(Siv_Decrypt(key, ad_vec, 3, out, 16 + pt_n, pt_back), 0);
    CHECK(bufs_eq(pt_back, pt, pt_n));
}

static void test_siv_edge_cases(void) {
    // Common NTS shape: one AD element (the SNTP header), zero-length
    // plaintext (empty encrypted-extensions field). Must still produce
    // a 16-byte authenticator and round-trip cleanly.
    uint8_t key[32];
    for (int i = 0; i < 32; i++) key[i] = (uint8_t)i;

    uint8_t ad[48];
    for (int i = 0; i < 48; i++) ad[i] = (uint8_t)(0xA0 + i);
    SivSlice ad_vec = { ad, sizeof ad };

    uint8_t tag[16];
    CHECK_EQ_INT(Siv_Encrypt(key, &ad_vec, 1, NULL, 0, tag), 0);
    CHECK_EQ_INT(Siv_Decrypt(key, &ad_vec, 1, tag, 16, NULL), 0);

    // Flip one AD byte -> authentication MUST fail and the (empty)
    // plaintext buffer MUST NOT be written past length 0.
    ad[7] ^= 0x01;
    CHECK_EQ_INT(Siv_Decrypt(key, &ad_vec, 1, tag, 16, NULL), -1);
    ad[7] ^= 0x01;

    // Zero AD, non-empty plaintext -- exercises the n==0 S2V path.
    uint8_t pt[20] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
                       11, 12, 13, 14, 15, 16, 17, 18, 19, 20 };
    uint8_t out2[64];
    CHECK_EQ_INT(Siv_Encrypt(key, NULL, 0, pt, sizeof pt, out2), 0);
    uint8_t pt_back[32];
    CHECK_EQ_INT(Siv_Decrypt(key, NULL, 0, out2, 16 + sizeof pt, pt_back), 0);
    CHECK(bufs_eq(pt_back, pt, sizeof pt));

    // Tamper one ciphertext byte -> auth must fail, plaintext wiped.
    out2[20] ^= 0x80;
    for (size_t i = 0; i < sizeof pt; i++) pt_back[i] = 0xCC;
    CHECK_EQ_INT(Siv_Decrypt(key, NULL, 0, out2, 16 + sizeof pt, pt_back), -1);
    for (size_t i = 0; i < sizeof pt; i++) CHECK_EQ_INT(pt_back[i], 0);

    // Short input (< 16 bytes) rejected outright without reading key/AD.
    CHECK_EQ_INT(Siv_Decrypt(key, NULL, 0, out2, 10, pt_back), -1);
}


int main(void) {
    test_siv_rfc5297_appendix_a1(); test_siv_rfc5297_appendix_a2(); test_siv_edge_cases();
    printf("RFC 5297 AES-SIV vectors and authenticated decryption boundaries: %d checks passed\n", checks);
    return 0;
}
