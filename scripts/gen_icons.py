"""从 icon.png 生成 Android / Windows 的应用图标。

用法：
    python scripts/gen_icons.py

为什么手写而不用 flutter_launcher_icons：
- 本项目只出 Android + Windows 两端，目标路径固定；
- 不引入额外 pub 依赖，离线也能跑（CI/无网环境同样可用）。

输入：仓库根目录的 icon.png（1024x1024，带透明通道）
输出：
- android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png
- windows/runner/resources/app_icon.ico（多尺寸合成）
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "icon.png"

# Android 各密度下 launcher icon 的规范边长（px）
ANDROID = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# Windows ico 里要打包的尺寸（覆盖任务栏/资源管理器/大图标视图）
ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]


def resized(img: Image.Image, size: int) -> Image.Image:
    # LANCZOS：缩小时质量最好，边缘不会发糊
    return img.resize((size, size), Image.LANCZOS)


def main() -> int:
    if not SRC.is_file():
        print(f"找不到源图：{SRC}", file=sys.stderr)
        return 1

    img = Image.open(SRC).convert("RGBA")
    print(f"源图 {SRC.name}: {img.width}x{img.height}")

    if img.width != img.height:
        print("警告：源图不是正方形，缩放后会变形", file=sys.stderr)

    res_dir = ROOT / "android" / "app" / "src" / "main" / "res"
    for folder, size in ANDROID.items():
        out = res_dir / folder / "ic_launcher.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        resized(img, size).save(out, format="PNG", optimize=True)
        print(f"  Android {folder}: {size}x{size} -> {out.relative_to(ROOT)}")

    ico = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    ico.parent.mkdir(parents=True, exist_ok=True)
    # Pillow 的 ico 保存：sizes 决定内嵌哪几档，最大档单独给 256
    img.save(ico, format="ICO", sizes=[(s, s) for s in ICO_SIZES])
    print(f"  Windows ico: {ICO_SIZES} -> {ico.relative_to(ROOT)}")

    print("完成。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
