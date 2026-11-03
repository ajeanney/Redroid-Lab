#!/usr/bin/env python3
"""Summarize Apktool-decoded manifests and network security XML using the stdlib."""
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"
COMPONENTS = {"activity", "activity-alias", "service", "receiver", "provider"}


def attrs(element):
    return {key.removeprefix(ANDROID): value for key, value in element.attrib.items()}


def xml_node(element):
    node = {"tag": element.tag, "attributes": attrs(element)}
    if element.text and element.text.strip():
        node["text"] = element.text.strip()
    if len(element):
        node["children"] = [xml_node(child) for child in element]
    return node


def boolean(value, default):
    return default if value is None else {"true": True, "false": False}.get(value, value)


def class_name(package, name):
    return package + name if name.startswith(".") else package + "." + name if "." not in name else name


def report(directories):
    manifests = [(directory, ET.parse(directory / "AndroidManifest.xml").getroot()) for directory in directories]
    base = next((root for _, root in manifests if not root.get("split")), manifests[0][1])
    package = base.get("package", "")
    sdk = base.find("uses-sdk")
    target = sdk.get(ANDROID + "targetSdkVersion", sdk.get(ANDROID + "minSdkVersion", "1")) if sdk is not None else "1"
    target_number = int(target) if target.isdigit() else None
    app = base.find("application")
    defaults = attrs(app) if app is not None else {}
    result = {
        "package": package,
        "target_sdk": target,
        "application": {
            "debuggable": boolean(defaults.get("debuggable"), False),
            "allowBackup": boolean(defaults.get("allowBackup"), True),
            "enabled": boolean(defaults.get("enabled"), True),
            "usesCleartextTraffic": boolean(defaults.get("usesCleartextTraffic"),
                                             target_number < 28 if target_number is not None else "unknown"),
            "permission": defaults.get("permission"),
            "networkSecurityConfig": defaults.get("networkSecurityConfig"),
        },
        "permissions": [], "defined_permissions": [], "exported_components": [],
        "deep_links": [], "network_security_configs": [],
        "notes": ["Static manifest surface, not proof of runtime reachability or exploitability.",
                  "Resource-valued flags remain unresolved strings; inspect resource variants.",
                  "Network security config can override the cleartext flag; platform/transport backup rules may override allowBackup."],
    }
    for directory, root in manifests:
        for element in root:
            if element.tag in {"uses-permission", "uses-permission-sdk-23"}:
                result["permissions"].append({"apk": directory.name, **attrs(element)})
            elif element.tag == "permission":
                result["defined_permissions"].append(attrs(element))
        app = root.find("application")
        if app is None:
            continue
        application = {**defaults, **attrs(app)}
        activities = {class_name(package, e.get(ANDROID + "name", "")): attrs(e)
                      for _, manifest in manifests for a in manifest.findall("application")
                      for e in a.findall("activity")}
        for element in app:
            if element.tag not in COMPONENTS:
                continue
            values = attrs(element)
            name = class_name(package, values.get("name", ""))
            filters = [xml_node(f) for f in element.findall("intent-filter")]
            if element.tag == "provider":
                implicit_export = target_number <= 16 if target_number is not None else "unknown"
            else:
                implicit_export = bool(filters)
            exported = boolean(values.get("exported"), implicit_export)
            permission = values.get("permission", application.get("permission"))
            if element.tag == "activity-alias":
                target_activity = activities.get(class_name(package, values.get("targetActivity", "")), {})
                permission = values.get("permission", target_activity.get("permission", application.get("permission")))
            if exported is not False:
                entry = {"apk": directory.name, "type": element.tag, "name": name,
                         "exported": exported, "enabled": boolean(values.get("enabled"), True),
                         "application_enabled": boolean(application.get("enabled"), True),
                         "permission": permission, "attributes": values, "intent_filters": filters}
                if element.tag == "provider":
                    entry["readPermission"] = values.get("readPermission", permission)
                    entry["writePermission"] = values.get("writePermission", permission)
                    entry["path_permissions"] = [attrs(e) for e in element.findall("path-permission")]
                    entry["grant_uri_permissions"] = [attrs(e) for e in element.findall("grant-uri-permission")]
                result["exported_components"].append(entry)
            for intent in element.findall("intent-filter"):
                actions = [e.get(ANDROID + "name") for e in intent.findall("action")]
                if "android.intent.action.VIEW" in actions and intent.findall("data"):
                    result["deep_links"].append({"component": name, "exported": exported,
                                                 "intent_filter": xml_node(intent)})
        reference = application.get("networkSecurityConfig")
        if reference:
            match = re.fullmatch(r"@(?:[\w.]+:)?xml/([\w.]+)", reference)
            files = sorted((directory / "res").glob(f"xml*/{match[1]}.xml")) if match else []
            result["network_security_configs"].append({
                "apk": directory.name, "reference": reference,
                "resolved": bool(files),
                "variants": [{"path": str(path.relative_to(directory)), "config": xml_node(ET.parse(path).getroot())}
                             for path in files],
            })
    return result


def main():
    output = Path(sys.argv[1])
    try:
        result = report([Path(path) for path in sys.argv[2:]])
        temporary = output.with_suffix(output.suffix + ".part")
        temporary.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
        temporary.replace(output)
    except (OSError, ValueError, ET.ParseError) as error:
        print(f"error: manifest report failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
