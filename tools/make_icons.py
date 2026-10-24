"""生成「奥利给」的 tvOS 分层 App 图标和顶部横幅图（写入 Assets.xcassets）。

用法：python3 tools/make_icons.py tools/icon-source/dog.png TVBrowser/Assets.xcassets
需要 Pillow（pip install pillow）。
"""
import json
import os
import sys
from collections import deque

from PIL import Image, ImageDraw, ImageFilter

SOURCE, ROOT = sys.argv[1], sys.argv[2]
BRAND = os.path.join(ROOT, "App Icon & Top Shelf Image.brandassets")
INFO = {"version": 1, "author": "xcode"}

# 暖色渐变背景，黑色小狗在上面最显眼
TOP_COLOR = (255, 196, 77)
BOTTOM_COLOR = (255, 122, 61)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)


def cut_out_dog(path):
    """把图片四周连着边缘的白色背景抠成透明，只留下小狗（蓝色描边挡住了里面的白毛，不会被抠掉）。"""
    img = Image.open(path).convert("RGBA")
    w, h = img.size
    px = img.load()

    def is_background(p):
        r, g, b, _ = p
        return min(r, g, b) > 222 and max(r, g, b) - min(r, g, b) < 30

    seen = bytearray(w * h)
    queue = deque()
    for x in range(w):
        queue.append((x, 0))
        queue.append((x, h - 1))
    for y in range(h):
        queue.append((0, y))
        queue.append((w - 1, y))
    mask = Image.new("L", (w, h), 255)
    mpx = mask.load()
    while queue:
        x, y = queue.popleft()
        i = y * w + x
        if seen[i]:
            continue
        seen[i] = 1
        if not is_background(px[x, y]):
            continue
        mpx[x, y] = 0
        if x > 0: queue.append((x - 1, y))
        if x < w - 1: queue.append((x + 1, y))
        if y > 0: queue.append((x, y - 1))
        if y < h - 1: queue.append((x, y + 1))
    # 边缘稍微柔化，避免锯齿和白边
    mask = mask.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(1.2))
    img.putalpha(mask)
    return img.crop(img.getbbox())


DOG = cut_out_dog(SOURCE)


def gradient(w, h):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(TOP_COLOR[i] + (BOTTOM_COLOR[i] - TOP_COLOR[i]) * t) for i in range(3)))
    # 中间一圈淡淡的亮光，让小狗更突出
    glow = Image.new("L", (w, h), 0)
    r = int(min(w, h) * 0.55)
    ImageDraw.Draw(glow).ellipse([w // 2 - r, h // 2 - r, w // 2 + r, h // 2 + r], fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(r // 2))
    img.paste(Image.new("RGB", (w, h), (255, 236, 180)), (0, 0), glow)
    return img


def dog_layer(w, h, height_ratio=0.86, center_x=0.5):
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    target_h = int(h * height_ratio)
    target_w = int(DOG.width * target_h / DOG.height)
    dog = DOG.resize((target_w, target_h), Image.LANCZOS)
    x = int(w * center_x - target_w / 2)
    y = (h - target_h) // 2 + int(h * 0.02)
    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    alpha = dog.split()[3].point(lambda a: int(a * 0.35))
    shadow.paste(Image.new("RGBA", dog.size, (90, 30, 0, 255)), (x + int(h * 0.015), y + int(h * 0.03)), alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(max(2, h // 60)))
    layer = Image.alpha_composite(layer, shadow)
    layer.alpha_composite(dog, (x, y))
    return layer


def imagestack(name, sizes):
    base = os.path.join(BRAND, f"{name}.imagestack")
    write_json(os.path.join(base, "Contents.json"),
               {"layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}], "info": INFO})
    for layer, maker in (("Back", gradient), ("Front", dog_layer)):
        ldir = os.path.join(base, f"{layer}.imagestacklayer")
        write_json(os.path.join(ldir, "Contents.json"), {"info": INFO})
        idir = os.path.join(ldir, "Content.imageset")
        os.makedirs(idir, exist_ok=True)
        images = []
        for scale, w, h in sizes:
            fn = f"{layer.lower()}@{scale}.png"
            maker(w, h).save(os.path.join(idir, fn))
            images.append({"idiom": "tv", "filename": fn, "scale": scale})
        write_json(os.path.join(idir, "Contents.json"), {"images": images, "info": INFO})


def top_shelf(name, sizes):
    """顶部横幅图：暖色背景中间一个狗头，不放文字（App 名字由系统显示在图标下方）。"""
    idir = os.path.join(BRAND, f"{name}.imageset")
    os.makedirs(idir, exist_ok=True)
    images = []
    for scale, w, h in sizes:
        img = gradient(w, h).convert("RGBA")
        img = Image.alpha_composite(img, dog_layer(w, h, 0.9, 0.5))
        fn = f"shelf@{scale}.png"
        img.convert("RGB").save(os.path.join(idir, fn))
        images.append({"idiom": "tv", "filename": fn, "scale": scale})
    write_json(os.path.join(idir, "Contents.json"), {"images": images, "info": INFO})


write_json(os.path.join(ROOT, "Contents.json"), {"info": INFO})
imagestack("App Icon - Small", [("1x", 400, 240), ("2x", 800, 480)])
imagestack("App Icon - App Store", [("1x", 1280, 768)])
top_shelf("Top Shelf Image", [("1x", 1920, 720), ("2x", 3840, 1440)])
top_shelf("Top Shelf Image Wide", [("1x", 2320, 720), ("2x", 4640, 1440)])
write_json(os.path.join(BRAND, "Contents.json"), {
    "assets": [
        {"size": "1280x768", "idiom": "tv", "filename": "App Icon - App Store.imagestack", "role": "primary-app-icon"},
        {"size": "400x240", "idiom": "tv", "filename": "App Icon - Small.imagestack", "role": "primary-app-icon"},
        {"size": "2320x720", "idiom": "tv", "filename": "Top Shelf Image Wide.imageset", "role": "top-shelf-image-wide"},
        {"size": "1920x720", "idiom": "tv", "filename": "Top Shelf Image.imageset", "role": "top-shelf-image"},
    ],
    "info": INFO,
})
print("done")
