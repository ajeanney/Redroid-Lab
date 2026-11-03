// OpenSSL/BoringSSL exported TLS APIs, including modules loaded after spawn.
// shortcut: static/stripped TLS and app-specific native pin comparisons need targeted hooks.
(() => {
    const acceptCustom = new NativeCallback(() => 0, 'int', ['pointer', 'pointer']);
    const acceptChain = new NativeCallback(() => 1, 'int', ['pointer', 'pointer']);
    const modules = new Map();
    const setters = ['SSL_set_verify', 'SSL_CTX_set_verify', 'SSL_set_custom_verify',
        'SSL_CTX_set_custom_verify', 'SSL_CTX_set_cert_verify_callback'];
    const observer = Process.attachModuleObserver({
        onAdded(module) {
            const listeners = [];
            for (const name of [...setters, 'SSL_get_verify_result']) {
                const address = module.findExportByName(name);
                if (address === null) continue;
                try {
                    const callbacks = name === 'SSL_get_verify_result' ? {
                        onLeave(result) { result.replace(0); },
                    } : {
                        onEnter(args) {
                            if (name === 'SSL_CTX_set_cert_verify_callback') {
                                args[1] = acceptChain;
                                args[2] = ptr(0);
                            } else {
                                args[1] = ptr(0);
                                args[2] = name.includes('custom_verify') ? acceptCustom : ptr(0);
                            }
                        },
                    };
                    listeners.push(Interceptor.attach(address, callbacks));
                    console.log('[native-unpin] hooked ' + module.name + '!' + name);
                } catch (error) { console.log('[native-unpin] hook failed: ' + name + ': ' + error); }
            }
            if (listeners.length) modules.set(module.base.toString(), listeners);
        },
        onRemoved(module) {
            const key = module.base.toString();
            for (const listener of modules.get(key) || []) listener.detach();
            modules.delete(key);
        },
    });
    // Keep callback/observer handles alive for the attached script's lifetime.
    globalThis.redroidNativeUnpin = {acceptCustom, acceptChain, observer};
    console.log('[native-unpin] watching exported TLS APIs; only logged hooks are active');
})();
