/* Independent test-only RFC 8915 peer. Runs entirely on IPv4 loopback,
 * creates a fresh private CA/leaf in memory, and publishes just the CA DER
 * and ephemeral port under the invoking test's scratch directory. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/err.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *mode;
static void die(const char *reason) {fprintf(stderr,"NTS fixture: %s\n",reason);ERR_print_errors_fp(stderr);exit(2);}
static int alpn(SSL *ssl,const unsigned char **out,unsigned char *len,const unsigned char *in,unsigned n,void *user) {
    (void)ssl;(void)user;
    if (!strcmp(mode,"noalpn")) return SSL_TLSEXT_ERR_NOACK;
    if (n!=8 || in[0]!=7 || memcmp(in+1,"ntske/1",7)) return SSL_TLSEXT_ERR_ALERT_FATAL;
    *out=in+1;*len=7;return SSL_TLSEXT_ERR_OK;
}
static void extension(X509 *crt,X509 *issuer,int nid,const char *value) {
    X509V3_CTX context;
    X509V3_set_ctx(&context,issuer,crt,NULL,NULL,0);
    X509_EXTENSION *e=X509V3_EXT_conf_nid(NULL,&context,nid,value);
    if(!e || !X509_add_ext(crt,e,-1)) die("certificate extension");
    X509_EXTENSION_free(e);
}
static X509 *cert(EVP_PKEY *key,X509 *issuer,EVP_PKEY *signer,int leaf) {
    X509 *c=X509_new(); if(!c)die("certificate");
    X509_set_version(c,2);ASN1_INTEGER_set(X509_get_serialNumber(c),leaf?2:1);
    X509_gmtime_adj(X509_getm_notBefore(c),-86400);
    X509_gmtime_adj(X509_getm_notAfter(c),86400);
    X509_set_pubkey(c,key);X509_NAME *name=X509_get_subject_name(c);
    const char *cn=leaf?(!strcmp(mode,"wronghost")?"different.invalid":"localhost"):"Machteld test root";
    X509_NAME_add_entry_by_txt(name,"CN",MBSTRING_ASC,(const unsigned char*)cn,-1,-1,0);
    X509_set_issuer_name(c,issuer?X509_get_subject_name(issuer):name);
    extension(c,issuer?issuer:c,NID_basic_constraints,leaf?"critical,CA:FALSE":"critical,CA:TRUE");
    extension(c,issuer?issuer:c,NID_key_usage,leaf?"critical,digitalSignature":"critical,keyCertSign,cRLSign");
    if(leaf) {
        extension(c,issuer,NID_ext_key_usage,"serverAuth");
        extension(c,issuer,NID_subject_alt_name,!strcmp(mode,"wronghost")?"DNS:different.invalid":"DNS:localhost");
    }
    if(!X509_sign(c,signer,EVP_sha256()))die("certificate signature");
    return c;
}
static SOCKET local(int type,unsigned short *port) {
    int v6=type==SOCK_DGRAM && !strcmp(mode,"ipv6");
    SOCKET s=socket(v6?AF_INET6:AF_INET,type,0);if(s==INVALID_SOCKET)die("socket");
    struct sockaddr_storage ss={0};int len;
    if(v6){struct sockaddr_in6 *a=(void*)&ss;a->sin6_family=AF_INET6;a->sin6_addr=in6addr_loopback;len=sizeof *a;}
    else{struct sockaddr_in *a=(void*)&ss;a->sin_family=AF_INET;a->sin_addr.s_addr=htonl(INADDR_LOOPBACK);len=sizeof *a;}
    if(bind(s,(struct sockaddr *)&ss,len))die("bind");
    if(getsockname(s,(struct sockaddr *)&ss,&len))die("port");
    *port=v6?ntohs(((struct sockaddr_in6*)&ss)->sin6_port):ntohs(((struct sockaddr_in*)&ss)->sin_port);
    if(type==SOCK_STREAM&&listen(s,1))die("listen");
    DWORD timeout=7000;setsockopt(s,SOL_SOCKET,SO_RCVTIMEO,(char*)&timeout,sizeof timeout);
    return s;
}
static void put16(unsigned char *p,unsigned n) {p[0]=(unsigned char)(n>>8);p[1]=(unsigned char)n;}
static unsigned u16(const unsigned char *p) {return ((unsigned)p[0]<<8)|p[1];}
static void put32(unsigned char *p,uint32_t n) {for(int i=3;i>=0;--i){p[i]=(unsigned char)n;n>>=8;}}
static int record(unsigned char *p,unsigned type,const unsigned char *data,int n) {
    put16(p,type);put16(p+2,(unsigned)n);if(n)memcpy(p+4,data,(size_t)n);return n+4;
}
static void keys(SSL *ssl,unsigned char a[32],unsigned char b[32]) {
    const char *label="EXPORTER-network-time-security";unsigned char ctx[5]={0,0,0,15,0};
    if(!SSL_export_keying_material(ssl,a,32,label,strlen(label),ctx,5,1))die("export client key");
    ctx[4]=1;
    if(!SSL_export_keying_material(ssl,b,32,label,strlen(label),ctx,5,1))die("export server key");
}
/* Request plaintext has length zero. A completely independent S2V using
 * OpenSSL's CMAC checks its tag. Response encryption also exercises
 * genuine EVP AES-SIV with nonempty encrypted extensions. */
static void cmac16(const unsigned char *key,const unsigned char *data,size_t n,unsigned char out[16]) {
    size_t actual=0;
    if(!EVP_Q_mac(NULL,"CMAC",NULL,"AES-128-CBC",NULL,key,16,data,n,out,16,&actual)||actual!=16)die("CMAC");
}
static void twice(unsigned char p[16]) {
    unsigned carry=p[0]>>7;
    for(int i=0;i<15;i++)p[i]=(unsigned char)((p[i]<<1)|(p[i+1]>>7));
    p[15]=(unsigned char)((p[15]<<1)^(carry?0x87:0));
}
static int request_ok(const unsigned char *p,size_t n,const unsigned char key[32],const unsigned char cookie[32]) {
    if(n!=160 || p[0]!=0x23 || u16(p+48)!=0x0104 || u16(p+50)!=36 || u16(p+84)!=0x0204 ||
       u16(p+86)!=36 || memcmp(p+88,cookie,32) || u16(p+120)!=0x0404 || u16(p+122)!=40 ||
       u16(p+124)!=16 || u16(p+126)!=16) return 0;
    unsigned char zero[16]={0},d[16],m[16];
    cmac16(key,zero,16,d);
    cmac16(key,p,120,m);twice(d);for(int i=0;i<16;i++)d[i]^=m[i];
    cmac16(key,p+128,16,m);twice(d);for(int i=0;i<16;i++)d[i]^=m[i];
    twice(d);d[0]^=0x80; cmac16(key,d,16,m);
    return CRYPTO_memcmp(m,p+144,16)==0;
}
static void answer(SOCKET udp,const unsigned char s2c[32],const unsigned char c2s[32],const unsigned char cookie[32]) {
    unsigned char query[2048],p[256]={0};
    struct sockaddr_storage src; int len=sizeof src;
    int got=recvfrom(udp,(char *)query,sizeof query,0,(struct sockaddr*)&src,&len);
    if(got<0 || !request_ok(query,(size_t)got,c2s,cookie))die("request authentication");
    if(!strcmp(mode,"udpstall")){Sleep(4000);return;}
    p[0]=!strcmp(mode,"badmode")?0x23:0x24; p[1]=2;
    memcpy(p+24,query+40,8); if(!strcmp(mode,"origin"))p[24]^=1;
    /* Fixed 2036-02-07 06:28:17.250 UTC in era 1. */
    put32(p+32,1);put32(p+36,0x40000000);memcpy(p+40,p+32,8);
    put16(p+48,0x0104); put16(p+50,36);memcpy(p+52,query+52,32);
    if(!strcmp(mode,"uid"))p[52]^=1;
    put16(p+84,0x0404);put16(p+86,76);put16(p+88,16);put16(p+90,52);
    if(!RAND_bytes(p+92,16))die("nonce");
    unsigned char plain[36];put16(plain,0x0204);put16(plain+2,36);memcpy(plain+4,cookie,32);
    EVP_CIPHER_CTX *ctx=EVP_CIPHER_CTX_new();EVP_CIPHER *cipher=EVP_CIPHER_fetch(NULL,"AES-128-SIV",NULL);
    int n;
    if(!ctx || !cipher || !EVP_EncryptInit_ex2(ctx,cipher,s2c,NULL,NULL) ||
       !EVP_EncryptUpdate(ctx,NULL,&n,p,84) || !EVP_EncryptUpdate(ctx,NULL,&n,p+92,16) ||
       !EVP_EncryptUpdate(ctx,p+124,&n,plain,sizeof plain) || n!=36 ||
       !EVP_EncryptFinal_ex(ctx,p+160,&n) || !EVP_CIPHER_CTX_ctrl(ctx,EVP_CTRL_AEAD_GET_TAG,16,p+108)) die("AES-SIV response");
    EVP_CIPHER_free(cipher);EVP_CIPHER_CTX_free(ctx);
    if(!strcmp(mode,"tag"))p[108]^=1;
    if(!strcmp(mode,"timestamp"))p[40]^=1;
    if(sendto(udp,(char *)p,160,0,(struct sockaddr*)&src,len)!=160)die("UDP response");
}
int main(int argc,char **argv) {
    if(argc!=4) return 2;
    mode=argv[1];WSADATA w;
    if(WSAStartup(MAKEWORD(2,2),&w))die("Winsock");
    EVP_PKEY *root_key=EVP_PKEY_Q_keygen(NULL,NULL,"EC","P-256"),*key=EVP_PKEY_Q_keygen(NULL,NULL,"EC","P-256");
    if(!root_key||!key)die("fixture keys");
    X509 *root=cert(root_key,NULL,root_key,0),*leaf=cert(key,root,root_key,1);
    SSL_CTX *ctx=SSL_CTX_new(TLS_server_method());
    if(!ctx || !SSL_CTX_use_certificate(ctx,leaf)|| !SSL_CTX_use_PrivateKey(ctx,key))die("TLS identity");
    SSL_CTX_set_min_proto_version(ctx,TLS1_3_VERSION);SSL_CTX_set_max_proto_version(ctx,TLS1_3_VERSION);
    SSL_CTX_set_alpn_select_cb(ctx,alpn,NULL);
    SSL_CTX_set_num_tickets(ctx,!strcmp(mode,"tickets")?2:0);
    X509 *localroot=!strcmp(mode,"wrongroot")?cert(key,NULL,key,0):root;
    FILE *f=fopen(argv[2],"wb");if(!f || !i2d_X509_fp(f,localroot))die("DER root");fclose(f);
    if(localroot!=root)X509_free(localroot);
    unsigned short ke_port,udp_port;SOCKET tcp=local(SOCK_STREAM,&ke_port),udp=local(SOCK_DGRAM,&udp_port);
    f=fopen(argv[3],"wb");if(!f)die("port file");fprintf(f,"%u\n",ke_port);fclose(f);
    SOCKET peer=accept(tcp,NULL,NULL);if(peer==INVALID_SOCKET)die("accept");closesocket(tcp);
    SSL *ssl=SSL_new(ctx);SSL_set_fd(ssl,(int)peer);
    if(!strcmp(mode,"stall")){Sleep(4000);goto cleanup;}
    if(SSL_accept(ssl)!=1)goto cleanup;
    unsigned char request[16],c2s[32],s2c[32],cookie[32],body[128],num[2];
    size_t done=0;
    while(done<sizeof request) {
        int r=SSL_read(ssl,request+done,(int)(sizeof request-done));
        if(r<=0)goto cleanup;
        done+=(unsigned)r;
    }
    static const unsigned char expected[]={0x80,1,0,2,0,0,0x80,4,0,2,0,15,0x80,0,0,0};
    if(memcmp(request,expected,sizeof request))die("client KE request");
    if(!RAND_bytes(cookie,sizeof cookie))die("cookie");
    keys(ssl,c2s,s2c);
    int n=0;put16(num,0);n+=record(body+n,0x8001,num,2);
    put16(num,15);n+=record(body+n,0x8004,num,2);
    n+=record(body+n,5,cookie,sizeof cookie);
    if(!strcmp(mode,"ipv6")) n+=record(body+n,6,(unsigned char*)"::1",3);
    else if(strcmp(mode,"samepeer")) n+=record(body+n,6,(unsigned char*)"127.0.0.1",9);
    put16(num,udp_port);n+=record(body+n,7,num,2);
    if(!strcmp(mode,"critical"))n+=record(body+n,0x8aaa,NULL,0);
    if(!strcmp(mode,"warning"))n+=record(body+n,0x8003,num,2);
    if(!strcmp(mode,"duplicate"))n+=record(body+n,7,num,2);
    n+=record(body+n,0x8000,NULL,0);
    if(SSL_write(ssl,body,3)!=3 || SSL_write(ssl,body+3,n-3)!=n-3)goto cleanup;
    if(strcmp(mode,"critical")&&strcmp(mode,"warning")&&strcmp(mode,"duplicate"))answer(udp,s2c,c2s,cookie);
cleanup:
    SSL_free(ssl);SSL_CTX_free(ctx);closesocket(peer);closesocket(udp);
    X509_free(root);X509_free(leaf);EVP_PKEY_free(root_key);EVP_PKEY_free(key);WSACleanup();
    return 0;
}
