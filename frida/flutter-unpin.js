// Flutter's bundled BoringSSL: symbols first, verified per-build offsets otherwise.
// shortcut: stripped engines need a confirmed verifier offset and bytes from the same build.
(() => {
    let observer;
    const installed = new Map();
    rpc.exports = {
        init(stage, parameters) {
            if (observer) return;
            const config = parameters || {};
            observer = Process.attachModuleObserver({
                onAdded(module) {
                    if (module.name !== 'libflutter.so') return;
                    try {
                        let address, kind = 'chain';
                        if (config.flutterOffset !== undefined) {
                            if (!/^0x[0-9a-f]+$/i.test(config.flutterOffset) ||
                                !/^(?:[0-9a-f]{2}){8,64}$/i.test(config.flutterBytes || '') ||
                                !['chain', 'peer'].includes(config.flutterVerifier)) {
                                throw new Error('offset mode needs hex flutterOffset, 8-64 exact flutterBytes and flutterVerifier=chain|peer');
                            }
                            kind = config.flutterVerifier;
                            const offset = Number(config.flutterOffset);
                            if (!Number.isSafeInteger(offset) || offset < 0 || offset >= module.size) throw new Error('offset outside libflutter.so');
                            if (Process.arch === 'arm64' && offset % 4 !== 0) throw new Error('unaligned ARM64 offset');
                            address = module.base.add(offset);
                            const expected = config.flutterBytes.toLowerCase();
                            const bytes = expected.length / 2;
                            if (offset + bytes > module.size) throw new Error('bytes extend outside libflutter.so');
                            const range = Process.findRangeByAddress(address);
                            if (!range || !range.protection.includes('x') || address.add(bytes).compare(range.base.add(range.size)) > 0) {
                                throw new Error('verifier is not in an executable range');
                            }
                            const actual = Array.from(new Uint8Array(address.readByteArray(bytes)))
                                .map((b) => b.toString(16).padStart(2, '0')).join('');
                            if (actual !== expected) throw new Error('verifier bytes do not match this engine build');
                        } else {
                            const symbols = module.enumerateSymbols().filter((s) => s.type === 'function');
                            let matches = symbols.filter((s) => /(?:^|[0-9])ssl_crypto_x509_session_verify_cert_chain(?:E|$)/.test(s.name));
                            if (!matches.length) {
                                kind = 'peer';
                                matches = symbols.filter((s) => /(?:^|[0-9])ssl_verify_peer_cert(?:E|$)/.test(s.name));
                            }
                            if (matches.length !== 1) throw new Error('no unique verifier symbol; supply verified per-build offset/bytes parameters');
                            address = matches[0].address;
                        }
                        // BoringSSL chain verification returns bool 1; peer verification returns ssl_verify_ok 0.
                        const callback = new NativeCallback(() => kind === 'chain' ? 1 : 0,
                            'int', kind === 'chain' ? ['pointer', 'pointer', 'pointer'] : ['pointer']);
                        Interceptor.replace(address, callback);
                        installed.set(module.base.toString(), {address, callback});
                        console.log('[flutter-unpin] hooked ' + kind + ' verifier at ' + address + ' (' + Process.arch + ')');
                    } catch (error) { console.log('[flutter-unpin] NOT hooked: ' + error); }
                },
                onRemoved(module) {
                    const key = module.base.toString();
                    const hook = installed.get(key);
                    if (hook) {
                        try { Interceptor.revert(hook.address); } catch (error) { /* module already unmapped */ }
                    }
                    installed.delete(key);
                },
            });
            globalThis.redroidFlutterObserver = observer;
            console.log('[flutter-unpin] watching libflutter.so; require a hooked message before trusting capture');
        },
    };
})();
