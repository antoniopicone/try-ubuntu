#!/usr/bin/env python3
"""unzboot.py VMLINUZ OUT: writes the raw arm64 Image from an EFI zboot kernel.

Ubuntu's arm64 vmlinuz is a (signed) EFI application wrapping a zboot image:
a PE whose header carries "zimg", the payload offset/size and the compression
type. Bootloaders speaking the Linux boot protocol directly (Limine) need the
decompressed Image, which starts with the "ARM\\x64" magic at offset 56.
"""
import struct, subprocess, sys

src, out = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
if data[56:60] == b"ARM\x64":
    open(out, "wb").write(data)               # already a raw Image
    sys.exit(0)
pos = data.find(b"zimg")
while pos != -1 and data[pos - 4:pos - 2] != b"MZ":
    pos = data.find(b"zimg", pos + 1)
if pos == -1:
    sys.exit(f"{src}: neither a raw arm64 Image nor an EFI zboot image")
base = pos - 4
payload_off, payload_size = struct.unpack_from("<II", data, base + 8)
comp = data[base + 24:base + 32].rstrip(b"\0").decode()
payload = data[base + payload_off:base + payload_off + payload_size]
tools = {"zstd": ["zstd", "-dcq"], "gzip": ["gzip", "-dc"], "xz": ["xz", "-dc"], "lzma": ["xz", "-dc", "--format=lzma"]}
if comp not in tools:
    sys.exit(f"{src}: unsupported zboot compression '{comp}'")
image = subprocess.run(tools[comp], input=payload, stdout=subprocess.PIPE, check=True).stdout
if image[56:60] != b"ARM\x64":
    sys.exit(f"{src}: decompressed payload is not an arm64 Image")
open(out, "wb").write(image)
print(f"{src}: zboot/{comp} -> raw Image, {len(image)} bytes")
