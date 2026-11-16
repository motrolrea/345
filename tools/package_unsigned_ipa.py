#!/usr/bin/env python3
"""把 RizlineMod.framework 注入解包后的 2.7.1 Payload，产出未签名 IPA。

用法：
  python tools/package_unsigned_ipa.py \
      --source "e:\\Trae CN\\Clock\\_rizline\\ipa" \
      --framework "RizlineMod/build/RizlineMod.framework" \
      --output "RizlineMod_2.7.1_unsigned.ipa"

输出刻意保持未签名，装普通设备前必须用证书/描述文件重新签名（TrollStore 除外）。
"""
from __future__ import annotations
import argparse
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid
import zipfile
from pathlib import Path

DEPENDENCY = "@loader_path/../RizlineMod.framework/RizlineMod"
EXPECTED_UUID = "41d3a6b76c0d3f01a6cb0ddd615f3156"


def find_app(payload: Path) -> Path:
    apps = list(payload.glob("*.app"))
    if len(apps) != 1:
        raise RuntimeError(f"expected exactly one app under Payload, found {len(apps)}")
    return apps[0]


def macho_uuid(path: Path) -> str | None:
    data = path.read_bytes()[:0x10000]
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != 0xFEEDFACF:
        return None
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x1B and cmdsize >= 24:
            return uuid.UUID(bytes=bytes(data[off + 8:off + 24])).hex
        off += cmdsize
    return None


def strip_signatures(app: Path) -> None:
    for signature in app.rglob("_CodeSignature"):
        if signature.is_dir():
            shutil.rmtree(signature)
    for provision in app.rglob("embedded.mobileprovision"):
        provision.unlink()
    for sc in app.rglob("SC_Info"):
        if sc.is_dir():
            shutil.rmtree(sc)


def zip_tree(root: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(root)
            name = rel.as_posix()
            # Windows 解包会丢失 Unix 执行位：.app / .framework 内的文件统一给 0755
            executable = (
                path.suffix == ".dylib"
                or rel.parent.name.endswith(".framework")
                or rel.parent.name.endswith(".app")
            )
            entry = zipfile.ZipInfo.from_file(path, name)
            entry.create_system = 3
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = (0o100755 if executable else 0o100644) << 16
            with path.open("rb") as src, archive.open(entry, "w", force_zip64=True) as dst:
                shutil.copyfileobj(src, dst, 1024 * 1024)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, type=Path, help="含 Payload 的目录")
    ap.add_argument("--framework", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--skip-version-gate", action="store_true")
    args = ap.parse_args()

    payload = args.source / "Payload"
    if not payload.is_dir():
        raise RuntimeError(f"missing Payload: {payload}")
    exe = args.framework / "RizlineMod"
    if not exe.is_file():
        raise RuntimeError(f"missing framework executable: {exe}")

    app = find_app(payload)
    unity = app / "Frameworks/UnityFramework.framework/UnityFramework"
    got = macho_uuid(unity)
    print(f"UnityFramework UUID: {got}")
    if not args.skip_version_gate and got != EXPECTED_UUID:
        raise RuntimeError(
            f"版本门禁不匹配：需要 2.7.1 ({EXPECTED_UUID})，当前 {got}。"
            "如确认要强行打包，可加 --skip-version-gate（字段偏移很可能不对）。"
        )

    tools = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="rizlinemod-", dir=str(args.output.parent)) as tmp:
        stage = Path(tmp)
        shutil.copytree(payload, stage / "Payload", symlinks=True,
                        ignore=shutil.ignore_patterns("*.before-rizlinemod", "*.ipa"))
        app = find_app(stage / "Payload")
        destination = app / "Frameworks" / "RizlineMod.framework"
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(args.framework, destination, symlinks=True)

        unity = app / "Frameworks" / "UnityFramework.framework" / "UnityFramework"
        subprocess.run([sys.executable, str(tools / "inject_load_dylib.py"),
                        str(unity), DEPENDENCY, "--no-backup"], check=True)

        info = plistlib.loads((app / "Info.plist").read_bytes())
        print(f"target: {info.get('CFBundleDisplayName')} {info.get('CFBundleShortVersionString')}")

        strip_signatures(app)
        zip_tree(stage, args.output)

    print(f"unsigned IPA -> {args.output}")
    print("安装前请对 RizlineMod.framework / UnityFramework.framework / App 重新签名。")


if __name__ == "__main__":
    main()
