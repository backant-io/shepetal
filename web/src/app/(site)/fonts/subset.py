# Instance and subset the brand fonts for the website, renamed as the OFL and identity.md ask for modified fonts.
# From the repo root, with fontTools and brotli installed:
#   python3 web/src/app/'(site)'/fonts/subset.py brand/fonts/desktop/Newsreader-Variable.ttf web/src/app/'(site)'/fonts/shepetal-serif.woff2 "shepetal Serif" "{'wght': (300, 440), 'opsz': (16, 72)}"
#   python3 web/src/app/'(site)'/fonts/subset.py brand/fonts/desktop/HankenGrotesk-Variable.ttf web/src/app/'(site)'/fonts/shepetal-sans.woff2 "shepetal Sans" "{'wght': (400, 700)}"
import sys
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools import subset
src, out, family, axes = sys.argv[1], sys.argv[2], sys.argv[3], eval(sys.argv[4])
f = TTFont(src, lazy=False)
U = list(range(0x20, 0x7F)) + list(range(0xA0, 0x100)) + [0x160, 0x161, 0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2026, 0x2022, 0x2032, 0x2033, 0x2122, 0x2212, 0x2192, 0x00B7]
opts = subset.Options(); opts.flavor = 'woff2'; opts.layout_features = ['kern', 'liga', 'calt', 'tnum', 'lnum', 'pnum', 'ss01', 'case', 'locl']; opts.name_IDs = ['*']; opts.notdef_outline = True
s = subset.Subsetter(opts); s.populate(unicodes=U); s.subset(f)
f = instantiateVariableFont(f, axes)
name = f['name']
for rec in list(name.names):
    if rec.nameID in (1, 4, 16, 21): rec.string = family
    elif rec.nameID == 6: rec.string = family.replace(' ', '')
    elif rec.nameID == 3: rec.string = family + ' (website subset)'
f.flavor = 'woff2'; f.save(out)
print(out)
