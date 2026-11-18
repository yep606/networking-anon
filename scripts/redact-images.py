# Redact sensitive regions from demo screenshots and save cleaned copies.
from PIL import Image, ImageFilter
import shutil, os

SRC1 = r"C:\path\to\screenshot-iphone-geolocation.png"  # original screenshot
SRC2 = r"C:\path\to\screenshot-anyto-desktop.png"       # original screenshot
OUT = r"C:\path\to\output\images"
os.makedirs(OUT, exist_ok=True)

# --- Image 1: iPhone browserleaks geolocation proof (590x1280) ---
img1 = Image.open(SRC1).convert("RGB")
# Redact Cache Age value: contains real timezone offset "+0300"
img1.paste((255, 255, 255), (200, 332, 588, 372))
img1.save(os.path.join(OUT, "iphone-spoofed-geolocation.png"))

# --- Image 2: AnyTo on Windows desktop (1280x842) ---
orig2 = Image.open(SRC2).convert("RGB")
img2 = orig2.copy()

# 1) Redact terminal timestamps leaking real timezone (+03:00): 3 lines
img2.paste((12, 12, 12), (0, 205, 300, 270))  # black, matches terminal bg

# 2) Blur the AnyTo map (shows real-location Russian placenames),
#    keep title bar and tutorial popup sharp (pasted back from pristine copy).
win = (356, 19, 1271, 661)        # AnyTo window
title = (356, 19, 1271, 60)       # title bar strip
popup = (589, 179, 1033, 429)     # "This is search bar" popup
blurred = img2.crop(win).filter(ImageFilter.GaussianBlur(28))
img2.paste(blurred, win)
img2.paste(orig2.crop(title), title)
img2.paste(orig2.crop(popup), popup)
img2.save(os.path.join(OUT, "anyto-windows-desktop.png"))

print("done")
