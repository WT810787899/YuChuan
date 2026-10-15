# -*- coding: utf-8 -*-
"""雨传 YuChuan 应用图标生成：云 + 雨 + 传输纸飞机，靛紫渐变圆角方块。"""
import os
from PIL import Image, ImageDraw, ImageFilter

S = 1024  # 绘制尺寸（下采样抗锯齿）
R = 232   # 圆角半径

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def build():
    # 1) 对角渐变背景
    grad = Image.new("RGB", (S, S))
    px = grad.load()
    c1 = (0x5B, 0x5F, 0xEA)   # 靛蓝
    c2 = (0x8B, 0x5C, 0xF6)   # 紫
    for y in range(S):
        for x in range(0, S, 4):
            t = (x / S * 0.6 + y / S * 0.4)
            col = lerp(c1, c2, max(0.0, min(1.0, t)))
            for k in range(4):
                if x + k < S:
                    px[x + k, y] = col

    # 2) 圆角遮罩
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=R, fill=255)
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(grad, (0, 0), mask)

    draw = ImageDraw.Draw(icon)

    # 3) 云（白色）：三个圆 + 一个圆角底座
    cloud_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cd = ImageDraw.Draw(cloud_layer)
    cd.ellipse([232, 300, 452, 520], fill=(255, 255, 255, 255))
    cd.ellipse([372, 236, 668, 532], fill=(255, 255, 255, 255))
    cd.ellipse([560, 316, 762, 518], fill=(255, 255, 255, 255))
    cd.rounded_rectangle([232, 400, 762, 520], radius=60, fill=(255, 255, 255, 255))
    icon = Image.alpha_composite(icon, cloud_layer)
    draw = ImageDraw.Draw(icon)

    # 4) 雨（半透明白，斜向短线）：圆头短划，大小递减
    rain = [(318, 566, 250), (452, 604, 205), (596, 566, 250)]
    for i, (x, y, length) in enumerate(rain):
        alpha = (240, 175, 220)[i]
        draw.line([(x, y), (x - 22, y + length)], fill=(255, 255, 255, alpha), width=30)

    # 5) 纸飞机（传输）：右下角，更大更清晰
    plane = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    pd = ImageDraw.Draw(plane)
    pd.polygon([(420, 866), (900, 620), (712, 912)], fill=(255, 255, 255, 255))
    pd.polygon([(420, 866), (712, 912), (600, 826)], fill=(224, 224, 255, 255))
    icon = Image.alpha_composite(icon, plane)

    # 6) 轻微内阴影/高光，让体积感强一点
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([-260, -320, 720, 480], fill=(255, 255, 255, 26))
    glow = glow.filter(ImageFilter.GaussianBlur(60))
    icon = Image.alpha_composite(icon, glow)

    return icon.resize((512, 512), Image.LANCZOS)

def main():
    base = r"D:\Coding\TEST"
    icon = build()
    sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, size in sizes.items():
        d = os.path.join(base, "android", "app", "src", "main", "res", folder)
        os.makedirs(d, exist_ok=True)
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(d, "ic_launcher.png"))
        print("wrote", folder, size)

    # Windows .ico（多尺寸）
    ico_path = os.path.join(base, "windows", "runner", "resources", "app_icon.ico")
    big = build()
    big.save(ico_path, format="ICO",
             sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (24, 24), (16, 16)])
    print("wrote", ico_path)

    preview = os.path.join(base, "build", "icon_preview.png")
    os.makedirs(os.path.dirname(preview), exist_ok=True)
    build().resize((192, 192), Image.LANCZOS).save(preview)
    print("preview", preview)

main()
