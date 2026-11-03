// Trace Java crypto without changing return values or exceptions.
// shortcut: byte dumps stop at 4096 bytes; use a targeted hook for larger messages or native crypto.
(() => {
    Java.perform(() => {
        const dump = (value) => {
            if (value === null) return null;
            const length = value.length;
            let hex = '';
            for (let i = 0; i < Math.min(length, 4096); i++) hex += (value[i] & 255).toString(16).padStart(2, '0');
            return {length, hex, truncated: length > 4096};
        };
        const describe = (value, type) => {
            if (type === '[B') return dump(value);
            if (type === 'java.nio.ByteBuffer' && value !== null) {
                const copy = value.duplicate();
                const length = copy.remaining();
                const bytes = Java.array('byte', new Array(Math.min(length, 4096)).fill(0));
                copy.get(bytes);
                return {...dump(bytes), length, truncated: length > 4096};
            }
            if (['byte', 'int', 'long'].includes(type)) return String(value);
            return type;
        };
        for (const [name, methods] of [
            ['javax.crypto.Cipher', ['init', 'update', 'updateAAD', 'doFinal']],
            ['javax.crypto.Mac', ['init', 'update', 'doFinal']],
            ['java.security.MessageDigest', ['update', 'digest']],
        ]) {
            const klass = Java.use(name);
            for (const method of methods) {
                klass[method].overloads.forEach((overload) => {
                    overload.implementation = function (...args) {
                        let event;
                        try {
                            event = {time: new Date().toISOString(), thread: Process.getCurrentThreadId(),
                                object: String(this.hashCode()), algorithm: String(this.getAlgorithm()),
                                class: name, method, inputs: args.map((v, i) => describe(v, overload.argumentTypes[i].className))};
                            if (method === 'init') {
                                const key = args[name === 'javax.crypto.Cipher' ? 1 : 0];
                                event.key = key === null ? null : dump(key.getEncoded());
                                if (event.key === null) event.keyNote = 'key is absent or non-exportable';
                            }
                        } catch (error) { console.log('[crypto] input trace unavailable: ' + error); }
                        const result = overload.apply(this, args);
                        try {
                            if (event) {
                                event.output = describe(result, overload.returnType.className);
                                event.buffersAfter = args.map((v, i) => describe(v, overload.argumentTypes[i].className));
                                if (name === 'javax.crypto.Cipher' && method === 'init') event.iv = dump(this.getIV());
                                console.log('[crypto] ' + JSON.stringify(event));
                            }
                        } catch (error) { console.log('[crypto] output trace unavailable: ' + error); }
                        return result;
                    };
                });
            }
            console.log('[crypto] hooked ' + name);
        }
    });
})();
