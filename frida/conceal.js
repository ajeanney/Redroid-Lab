// Bypass common local root/emulator checks in this process only.
// shortcut: custom checks, mount/proc inspection and server-side integrity attestation are not covered.
(() => {
    const properties = Object.assign(Object.create(null), {
        'ro.kernel.qemu': '0', 'ro.debuggable': '0', 'ro.secure': '1',
        'ro.build.tags': 'release-keys', 'ro.build.type': 'user',
        'ro.product.model': 'Pixel 7', 'ro.product.manufacturer': 'Google',
        'ro.product.brand': 'google', 'ro.product.device': 'panther',
        'ro.product.name': 'panther', 'ro.hardware': 'panther',
        'ro.build.fingerprint': 'google/panther/panther:14/AP2A.240905.003/12231197:user/release-keys',
    });
    const hidden = new Set(['/system/bin/su', '/system/xbin/su', '/sbin/su', '/su/bin/su',
        '/data/adb/magisk', '/system/app/Superuser.apk', '/system/bin/magisk',
        '/dev/qemu_pipe', '/dev/socket/qemud', '/dev/socket/genyd']);
    const absent = Memory.allocUtf8String('/redroid-lab-hidden/unavailable');
    const libc = Process.getModuleByName('libc.so');
    for (const [name, index] of [['open', 0], ['openat', 1], ['fopen', 0], ['access', 0],
        ['faccessat', 1], ['stat', 0], ['lstat', 0]]) {
        const address = libc.findExportByName(name);
        if (address === null) continue;
        Interceptor.attach(address, {onEnter(args) {
            try { if (hidden.has(args[index].readUtf8String())) args[index] = absent; } catch (error) { /* invalid caller pointer */ }
        }});
    }
    const propertyGet = libc.findExportByName('__system_property_get');
    if (propertyGet !== null) Interceptor.attach(propertyGet, {
        onEnter(args) {
            this.value = properties[args[0].readUtf8String()];
            this.output = args[1];
        },
        onLeave(result) {
            if (this.value !== undefined) {
                this.output.writeUtf8String(this.value);
                result.replace(this.value.length);
            }
        },
    });
    if (!Java.available) { console.log('[conceal] native hooks only; Java unavailable'); return; }
    Java.perform(() => {
        const Build = Java.use('android.os.Build');
        for (const [field, value] of Object.entries({MODEL: 'Pixel 7', MANUFACTURER: 'Google',
            BRAND: 'google', DEVICE: 'panther', PRODUCT: 'panther', HARDWARE: 'panther',
            TAGS: 'release-keys', TYPE: 'user', FINGERPRINT: properties['ro.build.fingerprint']})) {
            Build[field].value = value;
        }
        const SystemProperties = Java.use('android.os.SystemProperties');
        for (const method of ['get', 'getInt', 'getLong', 'getBoolean']) {
            SystemProperties[method].overloads.forEach((overload) => {
                overload.implementation = function (...args) {
                    const value = properties[String(args[0])];
                    if (value === undefined) return overload.apply(this, args);
                    if (method === 'getBoolean') return value === '1' || value === 'true';
                    if (method === 'getInt' || method === 'getLong') return /^\d+$/.test(value) ? Number(value) : args[1];
                    return value;
                };
            });
        }
        const File = Java.use('java.io.File');
        const exists = File.exists.overload();
        exists.implementation = function () {
            return hidden.has(String(this.getAbsolutePath())) ? false : exists.call(this);
        };
        const Runtime = Java.use('java.lang.Runtime');
        Runtime.exec.overloads.forEach((overload) => {
            overload.implementation = function (...args) {
                const array = overload.argumentTypes[0].className === '[Ljava.lang.String;';
                const words = array ? Array.from(args[0], String) : String(args[0]).trim().split(/\s+/);
                const command = words[0].split('/').pop();
                if (['su', 'magisk'].includes(command) || (command === 'which' && words[1] === 'su')) {
                    args[0] = array ? Java.array('java.lang.String', ['/system/bin/false']) : '/system/bin/false';
                }
                return overload.apply(this, args);
            };
        });
        try {
            const RootBeer = Java.use('com.scottyab.rootbeer.RootBeer');
            for (const method of ['isRooted', 'isRootedWithoutBusyBoxCheck', 'checkForSuBinary',
                'checkForMagiskBinary', 'detectRootManagementApps', 'detectPotentiallyDangerousApps',
                'checkForRWPaths', 'detectTestKeys', 'checkSuExists', 'checkForDangerousProps']) {
                if (RootBeer[method]) RootBeer[method].overloads.forEach((overload) => {
                    if (overload.returnType.className === 'boolean') overload.implementation = () => false;
                });
            }
        } catch (error) { console.log('[conceal] RootBeer absent'); }
        console.log('[conceal] common Java and native checks hooked; attestation is unchanged');
    });
})();
