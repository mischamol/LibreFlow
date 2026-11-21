#!/usr/bin/env python3
"""Build the iPhone app's analysis page from web/libreflow.html (the single source).

The app version loads Chart.js and JSZip from the app bundle instead of the internet (the app blocks all
network access for the page) and adjusts a few phone-specific texts. Run automatically by the Xcode build;
fails loudly when one of the fragments below no longer exists, so a change in the page is never silently lost.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "web", "libreflow.html")
DST = os.path.join(ROOT, "LibreFlow", "Web", "index.html")

PAIRS = [
    ('<script src="https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js"></script>', '<script src="jszip.min.js"></script>'),
    ('<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>', '<script src="chart.umd.min.js"></script>'),
    ('<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.css">', '<link rel="stylesheet" href="leaflet.css">'),
    ('<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.js"></script>', '<script src="leaflet.js"></script>'),
    ('Your own Polar history, analysed locally.', 'Your own Polar history, analysed on your phone.'),
    # (the import card itself is hidden in the app: importing lives in the app's Settings tab)
    ('Unzip it and choose the folder. Error: ', 'Try a backup made on your Mac instead. Error: '),
]


def main():
    html = open(SRC, encoding="utf-8").read()
    missing = [a for a, _ in PAIRS if a not in html]
    for a, b in PAIRS:
        html = html.replace(a, b)
    os.makedirs(os.path.dirname(DST), exist_ok=True)
    with open(DST, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"-> {DST}")
    if missing:
        print("error: these fragments are no longer in libreflow.html (update make_app_page.py):", file=sys.stderr)
        for m in missing:
            print("   " + m[:120], file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
