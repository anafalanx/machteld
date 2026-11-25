/* The NTS-KE peer is authenticated by Windows, with a caller-supplied
 * exclusive in-memory root only when requested. No OS certificate store is
 * changed. Export keys are tied to the negotiated TLS 1.3 session. */
#define SECURITY_WIN32
#define SCHANNEL_USE_BLACKLISTS
#include "nts_client.h"
#include <security.h>
#include <schannel.h>
#include <wincrypt.h>
#include <stddef.h>
#include <string.h>

typedef struct {
    CredHandle cred; CtxtHandle ctx;
    unsigned char input[65536], plain[16384];
    size_t have, used;
    NtsSocket *socket;
} Tls;

static int pull(Tls *t) {
    if (t->have == sizeof t->input) return nts_fail(t->socket->job, "TLS record size", ERROR_INVALID_DATA);
    int n = nts_recv(t->socket, t->input + t->have, sizeof t->input - t->have);
    if (n < 0) return 0;
    if (!n) return nts_fail(t->socket->job, "TLS truncated", ERROR_HANDLE_EOF);
    t->have += (size_t)n;
    return 1;
}
static void consume(Tls *t, SecBuffer *v, int count) {
    size_t remaining = 0;
    for (int i = 0; i < count; ++i) if (v[i].BufferType == SECBUFFER_EXTRA) remaining = v[i].cbBuffer;
    memmove(t->input, t->input + t->have - remaining, remaining);
    t->have = remaining;
}
static int handshake(Tls *t, int initial) {
    NtsJob *job = t->socket->job;
    union {SEC_APPLICATION_PROTOCOLS align; unsigned char bytes[64];} protocols = {0};
    SEC_APPLICATION_PROTOCOLS *p = &protocols.align;
    p->ProtocolListsSize = (ULONG)offsetof(SEC_APPLICATION_PROTOCOL_LIST, ProtocolList) + 8;
    p->ProtocolLists[0].ProtoNegoExt = SecApplicationProtocolNegotiationExt_ALPN;
    p->ProtocolLists[0].ProtocolListSize = 8;
    memcpy(p->ProtocolLists[0].ProtocolList, "\x07ntske/1", 8);
    for (;;) {
        if (!initial && !t->have && !pull(t)) return 0;
        SecBuffer in[2] = {{0}}, out[2] = {{0}};
        in[0].BufferType = initial ? SECBUFFER_APPLICATION_PROTOCOLS : SECBUFFER_TOKEN;
        in[0].cbBuffer = initial ? (ULONG)offsetof(SEC_APPLICATION_PROTOCOLS, ProtocolLists) + p->ProtocolListsSize : (ULONG)t->have;
        in[0].pvBuffer = initial ? (void *)p : (void *)t->input;
        out[0].BufferType = SECBUFFER_TOKEN; out[1].BufferType = SECBUFFER_ALERT;
        SecBufferDesc id = {SECBUFFER_VERSION, 2, in}, od = {SECBUFFER_VERSION, 2, out};
        ULONG attr = 0;
        SECURITY_STATUS sc = InitializeSecurityContextW(&t->cred, initial ? NULL : &t->ctx, job->host,
            ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM | ISC_REQ_CONFIDENTIALITY | ISC_REQ_REPLAY_DETECT | ISC_REQ_SEQUENCE_DETECT,
            0, SECURITY_NATIVE_DREP, &id, 0, &t->ctx, &od, &attr, NULL);
        int sent = !out[0].cbBuffer || nts_send(t->socket, out[0].pvBuffer, out[0].cbBuffer);
        for (int i = 0; i < 2; ++i) if (out[i].pvBuffer) FreeContextBuffer(out[i].pvBuffer);
        if (!sent) return 0;
        if (sc == SEC_E_INCOMPLETE_MESSAGE) {if (!pull(t)) return 0; continue;}
        if (sc != SEC_E_OK && sc != SEC_I_CONTINUE_NEEDED) return nts_fail(job, "TLS handshake", (DWORD)sc);
        consume(t, in, 2); initial = 0;
        if (sc == SEC_E_OK) return 1;
    }
}
static int private_chain(NtsJob *job, CtxtHandle *ctx) {
    PCCERT_CONTEXT leaf = NULL;
    SECURITY_STATUS sc = QueryContextAttributesW(ctx, SECPKG_ATTR_REMOTE_CERT_CONTEXT, &leaf);
    if (sc != SEC_E_OK) return nts_fail(job, "TLS certificate", (DWORD)sc);
    HCERTSTORE roots = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, NULL);
    HCERTCHAINENGINE engine = NULL; PCCERT_CHAIN_CONTEXT chain = NULL;
    DWORD err = 0;
    CERT_CHAIN_ENGINE_CONFIG cfg = {0}; cfg.cbSize = sizeof cfg; cfg.hExclusiveRoot = roots;
    CERT_CHAIN_PARA para = {0}; para.cbSize = sizeof para;
    char *usage = szOID_PKIX_KP_SERVER_AUTH;
    para.RequestedUsage.Usage.cUsageIdentifier = 1; para.RequestedUsage.Usage.rgpszUsageIdentifier = &usage;
    if (!roots || !CertAddEncodedCertificateToStore(roots, X509_ASN_ENCODING, job->trust, job->trust_len,
        CERT_STORE_ADD_ALWAYS, NULL) || !CertCreateCertificateChainEngine(&cfg, &engine) ||
        !CertGetCertificateChain(engine, leaf, NULL, leaf->hCertStore, &para,
             CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL | CERT_CHAIN_DISABLE_AUTH_ROOT_AUTO_UPDATE, NULL, &chain)) err = GetLastError();
    else {
        SSL_EXTRA_CERT_CHAIN_POLICY_PARA ssl = {0};
        ssl.cbSize = sizeof ssl; ssl.dwAuthType = AUTHTYPE_SERVER; ssl.pwszServerName = job->host;
        CERT_CHAIN_POLICY_PARA policy = {0}; policy.cbSize = sizeof policy; policy.pvExtraPolicyPara = &ssl;
        CERT_CHAIN_POLICY_STATUS status = {0}; status.cbSize = sizeof status;
        if (!CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, chain, &policy, &status)) err = GetLastError();
        else err = status.dwError;
    }
    if (chain) CertFreeCertificateChain(chain);
    if (engine) CertFreeCertificateChainEngine(engine);
    if (roots) CertCloseStore(roots, 0);
    CertFreeCertificateContext(leaf);
    return !err || nts_fail(job, "TLS certificate", err);
}
static int negotiated(Tls *t) {
    NtsJob *job = t->socket->job;
    SecPkgContext_ConnectionInfo ci; SecPkgContext_ApplicationProtocol ap;
    SECURITY_STATUS sc = QueryContextAttributesW(&t->ctx, SECPKG_ATTR_CONNECTION_INFO, &ci);
    if (sc || ci.dwProtocol != SP_PROT_TLS1_3_CLIENT) return nts_fail(job, "TLS version", sc ? (DWORD)sc : ERROR_INVALID_DATA);
    sc = QueryContextAttributesW(&t->ctx, SECPKG_ATTR_APPLICATION_PROTOCOL, &ap);
    if (sc || ap.ProtoNegoStatus != SecApplicationProtocolNegotiationStatus_Success ||
        ap.ProtoNegoExt != SecApplicationProtocolNegotiationExt_ALPN || ap.ProtocolIdSize != 7 || memcmp(ap.ProtocolId, "ntske/1", 7))
        return nts_fail(job, "TLS ALPN", sc ? (DWORD)sc : ERROR_INVALID_DATA);
    return !job->trust || private_chain(job, &t->ctx);
}
static int export_key(Tls *t, unsigned char direction, uint8_t out[32]) {
    char label[] = "EXPORTER-network-time-security";
    unsigned char context[5] = {0, 0, 0, NTSKE_AEAD_AES_SIV_CMAC_256, direction};
    SecPkgContext_KeyingMaterialInfo param = {sizeof label, label, sizeof context, context, 32};
    SECURITY_STATUS sc = SetContextAttributesW(&t->ctx, SECPKG_ATTR_KEYING_MATERIAL_INFO, &param, sizeof param);
    if (sc) return nts_fail(t->socket->job, "TLS exporter", (DWORD)sc);
    SecPkgContext_KeyingMaterial key = {0};
    sc = QueryContextAttributesW(&t->ctx, SECPKG_ATTR_KEYING_MATERIAL, &key);
    int valid = sc == SEC_E_OK && key.pbKeyingMaterial && key.cbKeyingMaterial == 32;
    if (valid) memcpy(out, key.pbKeyingMaterial, 32);
    if (key.pbKeyingMaterial) {SecureZeroMemory(key.pbKeyingMaterial, key.cbKeyingMaterial); FreeContextBuffer(key.pbKeyingMaterial);}
    return valid || nts_fail(t->socket->job, "TLS exporter", sc ? (DWORD)sc : ERROR_INVALID_DATA);
}
static int send_request(Tls *t) {
    SecPkgContext_StreamSizes sizes;
    SECURITY_STATUS sc = QueryContextAttributesW(&t->ctx, SECPKG_ATTR_STREAM_SIZES, &sizes);
    if (sc) return nts_fail(t->socket->job, "TLS stream sizes", (DWORD)sc);
    unsigned char msg[4096];
    if (sizes.cbHeader > 2048 || sizes.cbTrailer > 1024) return nts_fail(t->socket->job, "TLS overhead", ERROR_INVALID_DATA);
    size_t n = NtsKe_BuildClientRequest(msg + sizes.cbHeader, 128);
    SecBuffer v[4] = {{sizes.cbHeader, SECBUFFER_STREAM_HEADER, msg},
        {(ULONG)n, SECBUFFER_DATA, msg + sizes.cbHeader},
        {sizes.cbTrailer, SECBUFFER_STREAM_TRAILER, msg + sizes.cbHeader + n}, {0}};
    SecBufferDesc d = {SECBUFFER_VERSION, 4, v};
    sc = EncryptMessage(&t->ctx, 0, &d, 0);
    if (sc) return nts_fail(t->socket->job, "TLS write", (DWORD)sc);
    for (int i = 0; i < 3; ++i) if (!nts_send(t->socket, v[i].pvBuffer, v[i].cbBuffer)) return 0;
    return 1;
}
static int end_record(const unsigned char *p, size_t n) {
    for (size_t i = 0; i + 4 <= n;) {
        unsigned type = ((unsigned)p[i] << 8) | p[i+1];
        size_t len = ((size_t)p[i+2] << 8) | p[i+3];
        if (len > n - i - 4) return 0;
        i += 4 + len;
        if ((type & 0x7fff) == 0) return 1;
    }
    return 0;
}
static int receive_keys(Tls *t, NtsKeys *keys) {
    while (!end_record(t->plain, t->used)) {
        if (!t->have && !pull(t)) return 0;
        SecBuffer v[4] = {{(ULONG)t->have, SECBUFFER_DATA, t->input}, {0},{0},{0}};
        SecBufferDesc d = {SECBUFFER_VERSION, 4, v};
        SECURITY_STATUS sc = DecryptMessage(&t->ctx, &d, 0, NULL);
        if (sc == SEC_E_INCOMPLETE_MESSAGE) {if (!pull(t)) return 0; continue;}
        if (sc != SEC_E_OK && sc != SEC_I_RENEGOTIATE) return nts_fail(t->socket->job, "TLS read", (DWORD)sc);
        for (int i = 0; i < 4; ++i) if (v[i].BufferType == SECBUFFER_DATA) {
            if (v[i].cbBuffer > sizeof t->plain - t->used) return nts_fail(t->socket->job, "NTS-KE size", ERROR_INVALID_DATA);
            memcpy(t->plain + t->used, v[i].pvBuffer, v[i].cbBuffer); t->used += v[i].cbBuffer;
        }
        consume(t, v, 4);
        if (sc == SEC_I_RENEGOTIATE && !handshake(t, 0)) return 0;
    }
    if (!NtsKe_ParseResponse(t->plain, t->used, &keys->ke)) return nts_fail(t->socket->job, "NTS-KE negotiation", ERROR_INVALID_DATA);
    return export_key(t, 0, keys->c2s) && export_key(t, 1, keys->s2c);
}

int nts_ke_exchange(NtsJob *job, NtsSocket *s, NtsKeys *keys) {
    Tls t = {0}; t.socket = s; SecInvalidateHandle(&t.ctx);
    TLS_PARAMETERS tls = {0}; tls.grbitDisabledProtocols = SP_PROT_TLS1_0_CLIENT|SP_PROT_TLS1_1_CLIENT|SP_PROT_TLS1_2_CLIENT;
    SCH_CREDENTIALS options = {0};
    options.dwVersion = SCH_CREDENTIALS_VERSION;
    options.dwFlags = SCH_CRED_NO_DEFAULT_CREDS | SCH_CRED_DISABLE_RECONNECTS |
        (job->trust ? SCH_CRED_MANUAL_CRED_VALIDATION : SCH_CRED_AUTO_CRED_VALIDATION);
    options.cTlsParameters = 1; options.pTlsParameters = &tls;
    SECURITY_STATUS sc = AcquireCredentialsHandleW(NULL, UNISP_NAME_W, SECPKG_CRED_OUTBOUND,
        NULL, &options, NULL, NULL, &t.cred, NULL);
    if (sc) return nts_fail(job, "TLS credentials", (DWORD)sc);
    int ok = handshake(&t, 1) && negotiated(&t) && send_request(&t) && receive_keys(&t, keys);
    if (SecIsValidHandle(&t.ctx)) DeleteSecurityContext(&t.ctx);
    FreeCredentialsHandle(&t.cred);
    SecureZeroMemory(&t, sizeof t);
    return ok;
}
