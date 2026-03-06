#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional

NVIDIA_DEVICES = [
    "/dev/nvidiactl",
    "/dev/nvidia-uvm",
    "/dev/nvidia-modeset",
    "/dev/nvidia-uvm-tools", 
    "/dev/nvidia-caps/nvidia-cap1",
    "/dev/nvidia-caps/nvidia-cap2",
]

def _text(elem: ET.Element, path: str) -> Optional[str]:
    child = elem.find(path)
    if child is None or child.text is None:
        return None
    t = child.text.strip()
    return t if t else None

def _int(elem: ET.Element, path: str) -> Optional[int]:
    t = _text(elem, path)
    try:
        x = int(t)
    except (TypeError, ValueError):
        x = None
    return x

def _get_dev_from_proc(i: int, gi: int, ci: int = None) -> str:
    fci = f"ci{ci}/" if ci is not None else ""
    path = Path(f"/proc/driver/nvidia/capabilities/gpu{i}/mig/gi{gi}/{fci}access")
    content = path.read_text().splitlines()
    minor = [ v.strip() for k, v in (x.split(":") for x in content) if k.strip() == "DeviceFileMinor" ]
    dev = f"/dev/nvidia-caps/nvidia-cap{int(minor[0])}" if minor else None
    return dev

def main(argv: Optional[list[str]] = None) -> int:
    try:
        xml_bytes = subprocess.check_output(["nvidia-smi", "-q", "-x"], stderr=subprocess.STDOUT)
    except FileNotFoundError:
        print("ERROR: nvidia-smi not found in PATH", file=sys.stderr)
        return 127
    except subprocess.CalledProcessError as e:
        print("ERROR: nvidia-smi failed:\n", e.output.decode(errors="replace"), file=sys.stderr)
        return e.returncode

    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError as e:
        print(f"ERROR: failed to parse XML from nvidia-smi: {e}", file=sys.stderr)
        return 2

    gpus = root.findall("./gpu")
    if not gpus:
        print("No <gpu> elements found in nvidia-smi XML output.", file=sys.stderr)
        return 3

    allowed = [int(c) for c in sys.argv[1] if c.isdigit()] if len(sys.argv) > 1 else None
    devices = []
    if allowed:
        for i, gpu in enumerate(gpus):
            devices_per_gpu = []
            mig_devices = gpu.findall("./mig_devices/mig_device")
            for md in mig_devices:
                mi = _int(md, "./index")
                if mi in allowed:
                    gi = _int(md, "./gpu_instance_id")
                    ci = _int(md, "./compute_instance_id")
                    gi_cap_dev = _get_dev_from_proc(i, gi)
                    ci_cap_dev = _get_dev_from_proc(i, gi, ci)
                    if gi_cap_dev and ci_cap_dev:
                        devices_per_gpu += [gi_cap_dev, ci_cap_dev]
            if devices_per_gpu:
                gpu_dev = f"/dev/nvidia{i}"
                devices += [gpu_dev, *devices_per_gpu]

    if devices:
        devices[:0] = NVIDIA_DEVICES
        #print(" DevicePolicy=closed " + "".join([f" DeviceAllow={dev}" for dev in devices]))
        print(" " + "".join([f" DeviceAllow={dev}" for dev in devices]))
    
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

