// Bypass Java-layer certificate pinning so the mitmproxy CA is accepted.
// shortcut: classes renamed by R8/ProGuard and pinning in native code are not covered, hook those by hand with `frida exec`.
Java.perform(() => {
    const hook = (name, install) => {
        try { install(); console.log('[unpin] hooked ' + name); } catch (e) { /* class absent in this app */ }
    };

    // Apps that build their own SSLContext get a TrustManager that accepts any chain.
    const TrustAll = Java.registerClass({
        name: 'lab.TrustAll',
        implements: [Java.use('javax.net.ssl.X509TrustManager')],
        methods: {
            checkClientTrusted() {},
            checkServerTrusted() {},
            getAcceptedIssuers() { return []; },
        },
    });
    hook('SSLContext.init', () => {
        Java.use('javax.net.ssl.SSLContext').init
            .overload('[Ljavax.net.ssl.KeyManager;', '[Ljavax.net.ssl.TrustManager;', 'java.security.SecureRandom')
            .implementation = function (km, tm, sr) { return this.init(km, [TrustAll.$new()], sr); };
    });

    // The platform trust manager: accept any chain. The host-aware overload returns the
    // validated chain, so hand the presented one back.
    hook('TrustManagerImpl.checkServerTrusted', () => {
        const Arrays = Java.use('java.util.Arrays');
        Java.use('com.android.org.conscrypt.TrustManagerImpl').checkServerTrusted.overloads.forEach((o) => {
            const returnsChain = o.returnType.className === 'java.util.List';
            o.implementation = function (chain) { return returnsChain ? Arrays.asList(chain) : undefined; };
        });
    });
    hook('NetworkSecurityTrustManager.checkPins', () => {
        Java.use('android.security.net.config.NetworkSecurityTrustManager').checkPins
            .implementation = function () {};
    });

    // OkHttp 3/4 CertificatePinner (Kotlin builds expose the real check as check$okhttp).
    hook('okhttp3.CertificatePinner', () => {
        const pinner = Java.use('okhttp3.CertificatePinner');
        pinner.check.overloads.forEach((o) => { o.implementation = function () {}; });
        if (pinner['check$okhttp']) pinner['check$okhttp'].implementation = function () {};
    });
});
