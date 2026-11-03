#!/usr/bin/env python3
"""Check manifest defaults, split components, deep links and security XML."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

SPEC = importlib.util.spec_from_file_location("manifest_report", Path(__file__).resolve().parents[1] / "lib/manifest_report.py")
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)
HEADER = '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.app"'


class ManifestReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def decoded(self, name, contents, split=""):
        directory = self.root / name
        directory.mkdir()
        (directory / "AndroidManifest.xml").write_text(HEADER + split + ">" + contents + "</manifest>")
        return directory

    def test_flags_permissions_components_deep_links_and_network_config(self):
        base = self.decoded("base", '''
<uses-sdk android:targetSdkVersion="34"/>
<uses-permission android:name="android.permission.INTERNET"/>
<permission android:name="com.example.PRIVATE" android:protectionLevel="signature"/>
<application android:debuggable="true" android:allowBackup="false" android:permission="com.example.PRIVATE" android:networkSecurityConfig="@xml/network_security_config">
  <activity android:name=".Public" android:exported="true" android:permission="">
    <intent-filter android:autoVerify="true">
      <action android:name="android.intent.action.VIEW"/>
      <category android:name="android.intent.category.BROWSABLE"/>
      <data android:scheme="https" android:host="example.com" android:pathPrefix="/open"/>
    </intent-filter>
  </activity>
  <activity android:name=".Hidden" android:exported="false"/>
  <activity-alias android:name=".Alias" android:targetActivity=".Public" android:exported="true"/>
  <service android:name=".Service" android:exported="true" android:enabled="false"/>
  <provider android:name=".PrivateProvider" android:authorities="com.example.private"/>
  <provider android:name=".Provider" android:exported="true" android:readPermission="com.example.READ">
    <path-permission android:pathPrefix="/private" android:readPermission="com.example.OTHER"/>
  </provider>
</application>''')
        config = base / "res/xml/network_security_config.xml"
        config.parent.mkdir(parents=True)
        config.write_text('<network-security-config><base-config cleartextTrafficPermitted="false"><trust-anchors><certificates src="user"/></trust-anchors></base-config></network-security-config>')
        split = self.decoded("feature", '<application><receiver android:name=".Receiver" android:exported="true"/></application>', ' split="feature"')
        report = REPORT.report([split, base])
        self.assertTrue(report["application"]["debuggable"])
        self.assertFalse(report["application"]["allowBackup"])
        self.assertFalse(report["application"]["usesCleartextTraffic"])
        components = {entry["name"].split(".")[-1]: entry for entry in report["exported_components"]}
        self.assertNotIn("Hidden", components)
        self.assertNotIn("PrivateProvider", components)
        self.assertEqual(components["Public"]["permission"], "")
        self.assertEqual(components["Alias"]["permission"], "")
        self.assertFalse(components["Service"]["enabled"])
        self.assertEqual(components["Receiver"]["permission"], "com.example.PRIVATE")
        self.assertEqual(components["Provider"]["readPermission"], "com.example.READ")
        self.assertEqual(len(report["deep_links"]), 1)
        self.assertTrue(any(c["resolved"] for c in report["network_security_configs"]))
        self.assertEqual(report["defined_permissions"][0]["protectionLevel"], "signature")

    def test_legacy_export_defaults_and_resource_flags_are_preserved(self):
        base = self.decoded("base", '''
<uses-sdk android:targetSdkVersion="16"/><application android:debuggable="@bool/debug">
<provider android:name="Provider"/>
<activity android:name=".Implicit"><intent-filter><action android:name="TEST"/></intent-filter></activity>
<service android:name=".Private"/>
</application>''')
        report = REPORT.report([base])
        self.assertEqual(report["application"]["debuggable"], "@bool/debug")
        self.assertTrue(report["application"]["allowBackup"])
        self.assertEqual(len(report["exported_components"]), 2)

    def test_unresolved_security_reference_is_explicit_and_invalid_xml_fails(self):
        base = self.decoded("base", '<application android:networkSecurityConfig="@0x7f123456"/>')
        self.assertFalse(REPORT.report([base])["network_security_configs"][0]["resolved"])
        (base / "AndroidManifest.xml").write_text("invalid")
        with self.assertRaises(ET.ParseError):
            REPORT.report([base])


if __name__ == "__main__":
    unittest.main()
