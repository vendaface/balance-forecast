# butterfly-effect.spec
# PyInstaller spec for Butterfly Effect
#
# Build:
#   pip install pyinstaller
#   pyinstaller butterfly-effect.spec
#
# Output: dist/butterfly-effect   (Linux/Mac binary)
#         dist/Butterfly Effect.app  (Mac, with --windowed)

import sys
from pathlib import Path
from PyInstaller.utils.hooks import collect_all, collect_data_files

block_cipher = None
SRC = Path(SPECPATH)   # directory containing this .spec file

# collect_all() gathers every submodule, data file, and binary for a package.
# Use it for packages that have complex submodule structures that PyInstaller
# misses with static import analysis alone.
flask_datas,      flask_bins,      flask_hidden      = collect_all('flask')
werkzeug_datas,   werkzeug_bins,   werkzeug_hidden   = collect_all('werkzeug')
playwright_datas, playwright_bins, playwright_hidden = collect_all('playwright')

a = Analysis(
    [str(SRC / 'main.py')],
    pathex=[str(SRC)],
    binaries=[*flask_bins, *werkzeug_bins, *playwright_bins],
    datas=[
        # Web UI
        (str(SRC / 'templates'),        'templates'),
        (str(SRC / 'static'),           'static'),
        (str(SRC / 'startup.html'),     '.'),
        # Config example & version
        (str(SRC / 'config.yaml.example'), '.'),
        (str(SRC / 'VERSION'),          '.'),
        *flask_datas,
        *werkzeug_datas,
        *playwright_datas,
    ],
    hiddenimports=[
        *flask_hidden,
        *werkzeug_hidden,
        *playwright_hidden,
        'flask.json',   # explicit — flask.__init__ imports this at line 5
        # AI providers
        'anthropic',
        'openai',
        'google.genai',
        # Other deps
        'icalendar',
        'yaml',
        'dotenv',
        'requests',
        'websockets',
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # Keep bundle lean — test frameworks not needed at runtime
        'pytest', 'unittest', 'doctest',
        'tkinter', 'matplotlib', 'numpy',
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='butterfly-effect',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,     # keep console so users can see startup errors
    disable_windowed_traceback=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=str(SRC / 'static' / 'favicon.svg') if sys.platform == 'darwin' else None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='butterfly-effect',
)

# ── macOS .app bundle (built when running on macOS) ──────────────────────────
if sys.platform == 'darwin':
    app = BUNDLE(
        coll,
        name='Butterfly Effect.app',
        icon=None,   # replace with an .icns file once one exists
        bundle_identifier='com.vendaface.butterfly-effect',
        info_plist={
            'CFBundleShortVersionString': Path(SPECPATH + '/VERSION').read_text().strip(),
            'CFBundleVersion':            Path(SPECPATH + '/VERSION').read_text().strip(),
            'NSHumanReadableCopyright':   'MIT License',
            'NSHighResolutionCapable':    True,
            'LSMinimumSystemVersion':     '13.0',
        },
    )
