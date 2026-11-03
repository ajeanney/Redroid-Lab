#!/usr/bin/env node
// Pure mocks: no Frida server, app, network or Android device.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const scripts = path.join(__dirname, '..', 'frida');

class Pointer {
    constructor(value, bytes = '0011223344556677') { this.value = value; this.bytes = bytes; }
    add(offset) { return new Pointer(this.value + offset, this.bytes); }
    compare(other) { return Math.sign(this.value - other.value); }
    toString() { return '0x' + this.value.toString(16); }
    readByteArray(length) { return Uint8Array.from(Buffer.from(this.bytes, 'hex').subarray(0, length)).buffer; }
}
function runtime(file, extra = {}) {
    const attached = new Map(), replaced = [], logs = [];
    let observer;
    const context = {
        console: {log: (line) => logs.push(line)}, rpc: {exports: {}},
        ptr: (value) => new Pointer(value),
        NativeCallback: function (fn, type, args) { fn.signature = [type, args]; return fn; },
        Process: {arch: 'x64', getCurrentThreadId: () => 7,
            attachModuleObserver: (value) => { observer = value; return {detach() {}}; },
            findRangeByAddress: () => ({base: new Pointer(4096), size: 4096, protection: 'r-x'})},
        Interceptor: {
            attach: (address, callbacks) => { attached.set(String(address), callbacks); return {detach() {}}; },
            replace: (address, callback) => replaced.push({address, callback}), revert() {},
        }, ...extra,
    };
    vm.createContext(context);
    vm.runInContext(fs.readFileSync(path.join(scripts, file), 'utf8'), context, {filename: file});
    return {context, attached, replaced, logs, get observer() { return observer; }};
}

// Native custom verification uses BoringSSL's success=0, OpenSSL's success=1.
{
    const run = runtime('native-unpin.js');
    run.observer.onAdded({name: 'libssl.so', base: new Pointer(4096),
        findExportByName: (name) => name});
    const args = [new Pointer(9), new Pointer(1), new Pointer(2)];
    run.attached.get('SSL_set_custom_verify').onEnter(args);
    assert.equal(args[1].value, 0);
    assert.equal(args[2](), 0);
    run.attached.get('SSL_CTX_set_cert_verify_callback').onEnter(args);
    assert.equal(args[1](), 1);
    assert.equal(args[2].value, 0);
    run.attached.get('SSL_set_verify').onEnter(args);
    assert.equal(args[2].value, 0);
    let returned;
    run.attached.get('SSL_get_verify_result').onLeave({replace: (value) => { returned = value; }});
    assert.equal(returned, 0);
    run.observer.onRemoved({base: new Pointer(4096)});
}

const flutterModule = (name) => ({name: 'libflutter.so', base: new Pointer(4096), size: 4096,
    enumerateSymbols: () => name ? [{type: 'function', name, address: new Pointer(4112)}] : []});
for (const [symbol, success] of [['_ZN4bsslL45ssl_crypto_x509_session_verify_cert_chainEPvS0_Ph', 1],
    ['_ZN4bssl20ssl_verify_peer_certEPv', 0]]) {
    const run = runtime('flutter-unpin.js');
    run.context.rpc.exports.init('early', {});
    run.observer.onAdded(flutterModule(symbol));
    assert.equal(run.replaced.length, 1);
    assert.equal(run.replaced[0].callback(), success);
}
{
    const run = runtime('flutter-unpin.js');
    run.context.rpc.exports.init('early', {});
    run.observer.onAdded(flutterModule());
    assert.equal(run.replaced.length, 0);
    assert(run.logs.some((line) => line.includes('NOT hooked')));
}
for (const [offset, bytes, expected] of [['0x10', '0011223344556677', 1],
    ['0x10', 'ffffffffffffffff', 0], ['0x10000', '0011223344556677', 0],
    ['bad', '0011223344556677', 0], ['0x10', '00', 0]]) {
    const run = runtime('flutter-unpin.js');
    run.context.rpc.exports.init('early', {flutterOffset: offset, flutterBytes: bytes, flutterVerifier: 'chain'});
    run.observer.onAdded(flutterModule());
    assert.equal(run.replaced.length, expected);
}

function method(types, result, original = () => result) {
    const overload = {argumentTypes: types.map((className) => ({className})),
        returnType: {className: result === undefined ? 'void' : typeof result === 'number' ? 'int' : '[B'},
        apply: (self, args) => original(...args), call: (self, ...args) => original(...args)};
    return {overloads: [overload], overload: () => overload, hook: overload};
}
// Java crypto records key/input/output while preserving buffers and exceptions.
{
    const classes = {};
    for (const name of ['javax.crypto.Cipher', 'javax.crypto.Mac', 'java.security.MessageDigest']) {
        classes[name] = Object.fromEntries(['init', 'update', 'updateAAD', 'doFinal', 'digest'].map((name) =>
            [name, method(['[B'], [3, 4])]));
    }
    classes['javax.crypto.Cipher'].init = method(['int', 'java.security.Key'], undefined);
    const failure = new Error('original crypto failure');
    classes['javax.crypto.Cipher'].doFinal = method([], undefined, () => { throw failure; });
    const run = runtime('crypto.js', {Java: {perform: (fn) => fn(), use: (name) => classes[name], array: (type, data) => data}});
    const self = {hashCode: () => 42, getAlgorithm: () => 'AES/GCM/NoPadding', getIV: () => [0, 1]};
    classes['javax.crypto.Cipher'].init.hook.implementation.call(self, 1, {getEncoded: () => [-1, 0]});
    const input = [1, 2];
    const result = classes['javax.crypto.Cipher'].update.hook.implementation.call(self, input);
    assert.deepEqual(input, [1, 2]);
    assert.deepEqual(result, [3, 4]);
    assert(run.logs.some((line) => line.includes('"key":{"length":2,"hex":"ff00"')));
    assert.throws(() => classes['javax.crypto.Cipher'].doFinal.hook.implementation.call(self), (error) => error === failure);
}

// Detection bypass hides only selected paths/commands and preserves unrelated calls.
{
    const Build = Object.fromEntries(['MODEL', 'MANUFACTURER', 'BRAND', 'DEVICE', 'PRODUCT', 'HARDWARE',
        'TAGS', 'TYPE', 'FINGERPRINT'].map((name) => [name, {value: 'old'}]));
    const properties = Object.fromEntries(['get', 'getInt', 'getLong', 'getBoolean'].map((name) =>
        [name, method(['java.lang.String', 'int'], 'original')]));
    const exists = method([], true);
    const exec = method(['java.lang.String'], undefined, (command) => command);
    const classes = {'android.os.Build': Build, 'android.os.SystemProperties': properties,
        'java.io.File': {exists}, 'java.lang.Runtime': {exec}};
    const run = runtime('conceal.js', {
        Memory: {allocUtf8String: (text) => text},
        Process: {getModuleByName: () => ({findExportByName: (name) => name})},
        Java: {available: true, perform: (fn) => fn(), array: (type, data) => data,
            use: (name) => { if (!classes[name]) throw new Error('absent'); return classes[name]; }},
    });
    assert.equal(Build.MODEL.value, 'Pixel 7');
    assert.equal(properties.get.hook.implementation.call({}, 'ro.kernel.qemu'), '0');
    assert.equal(properties.get.hook.implementation.call({}, 'toString'), 'original');
    assert.equal(exists.hook.implementation.call({getAbsolutePath: () => '/system/xbin/su'}), false);
    assert.equal(exists.hook.implementation.call({getAbsolutePath: () => '/data/user/0/app/files/document'}), true);
    assert.equal(exec.hook.implementation.call({}, 'su -c id'), '/system/bin/false');
    assert.equal(exec.hook.implementation.call({}, 'echo hello'), 'echo hello');
    const args = [{readUtf8String: () => '/system/bin/su'}];
    run.attached.get('open').onEnter(args);
    assert.equal(args[0], '/redroid-lab-hidden/unavailable');
}
console.log('Frida script mock checks passed');
