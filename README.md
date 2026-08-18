# CometBrowser for Playdate

**CometBrowser** is a fast, standalone, general-purpose web browser built specifically for the **Playdate handheld console** and **Playdate Simulator**.

Unlike single-purpose feed readers, CometBrowser lets you navigate to any web address, search the internet, fill out forms, click hyperlinks, and render HTML headings, paragraphs, lists, blockquotes, code blocks, tables, and images (SVG, WebP, JPEG, PNG, GIF, BMP, ICO) with 1-bit monochrome graphics on the 400x240 sharp LCD screen.

---

## Hardware Controls & Shortcuts

### Global

| Control | Action |
| :--- | :--- |
| **Physical Crank** | Scroll pages & list screens with kinetic inertia; moves the mouse cursor in HTML mode. |
| **A Button** | Confirm / follow the focused link / activate a form input / open the selected item. |
| **B Button (hold)** | Arm the Address Bar for keyboard launch; release to open the on-screen keyboard. |
| **B + Left** | **Back** in page history (while address bar is armed). |
| **B + Right** | **Forward** in page history (while address bar is armed). |
| **A + Left** | **Back** in page history (while on a page). |
| **A + Right** | **Forward** in page history (while on a page). |
| **Menu** | Open Playdate system menu (Home-Page, View mode, Settings, History, Clear Cookies). |

### Reader Mode

| Control | Action |
| :--- | :--- |
| **D-Pad Down** | Jump to the next link on the page (scroll down if none nearby). |
| **D-Pad Up** | Jump to the previous link on the page (scroll up if none nearby). |
| **A** | Follow the focused link / activate a form input. |
| **B** | Open the Address Bar pre-filled with the current URL. |
| **Crank** | Scroll with inertia. |

### HTML Mode (virtual mouse cursor)

| Control | Action |
| :--- | :--- |
| **D-Pad (hold)** | Move the mouse cursor in that direction. |
| **Crank** | Move the cursor up / down. |
| **Cursor near screen edge** | Auto-scroll the page. |
| **A** | Left-click the hovered link / activate a form input. |
| **B** | Open the Address Bar. |
| **Hovering a link** | URL status bar appears at the bottom of the screen. |

### Home Page (Speed Dial)

| Control | Action |
| :--- | :--- |
| **D-Pad Up / Down** | Move between grid rows. |
| **D-Pad Left / Right** | Move between grid columns. |
| **A** | Open the selected bookmark. |
| **B** | Open the Address Bar & search. |
| **Crank** | Scroll the grid. |

### Loading Screen

| Control | Action |
| :--- | :--- |
| **B** | Cancel the page load. |
| **Left** | Cancel the load and go **Back** in history. |

### Error Page

| Control | Action |
| :--- | :--- |
| **Left / Up** and **Right / Down** | Cycle through **Retry / Search / Home**. |
| **A** | Confirm the highlighted option. |
| **Left** | Go **Back** in history. |

### Bookmarks & History Pages

| Control | Action |
| :--- | :--- |
| **D-Pad Up / Down** | Navigate the list. |
| **A** | Open the selected entry. |
| **B** | Close and return to the Home Page. |

---

## Key Features

### Navigation & Search
- **Anywhere URL & Search Navigation**: Type any website address or search terms directly.
- **Multiple Search Engines**: DuckDuckGo Lite, FrogFind, Wiby, Wikipedia Search.
- **Full Browsing History**: Back/forward navigation with persistent history (50 entries) stored to disk.
- **Bookmarks**: Save and manage bookmarks, persisted to disk.
- **Default Speed Dial**: 9 pre-loaded bookmarks on the home page (Google, Wikipedia, Hacker News, etc.).

### Rendering
- **Dual Browsing Modes**:
  - **Reader Mode**: Distills articles for clean, distraction-free reading.
  - **HTML Mode**: Full visual layout with virtual mouse cursor, interactive forms, and clickable elements.
- **HTML Elements**: `<h1>`-`<h6>`, `<p>`, `<a>`, `<ul>`/`<ol>`/`<li>`, `<blockquote>`, `<code>`, `<pre>`, `<hr>`, `<br>`, `<img>`, `<table>`, `<details>`/`<summary>`, `<fieldset>`, `<select>`, `<dialog>`.
- **Form Support**: Text inputs, checkboxes, radio buttons, dropdowns, submit buttons, hidden fields, and `<button>` elements. Forms are submitted per the HTML spec (hidden inputs included, submit button name/value always appended).
- **Inline Styles**: Bold, italic, underline, strikethrough, code, small, sub/superscript, text alignment.
- **`<base href>` Support**: Resolves relative URLs correctly when a base element is present.
- **Meta Refresh Redirect**: Automatically follows `<meta http-equiv="refresh">` redirects after the specified delay.

### Image Decoding
- **SVG**: Full path rendering (M, L, H, V, C, S, T, A, Z commands), transforms, viewBox, CSS styles.
- **WebP (VP8)**: Lossy and lossless sub-images, full image decoding pipeline.
- **JPEG**: Baseline DCT decoding with Huffman tables.
- **PNG**: Interlaced and non-interlaced, palette and truecolor, transparency.
- **GIF**: Animated and static, frame-by-frame rendering.
- **BMP**: 1-bit and 8-bit bitmaps with palette support.
- **ICO**: Favicon extraction from website icons.
- **1-bit Dithering**: Ordered dithering for grayscale-to-monochrome conversion.

### Image Rendering Modes
Configurable via **Settings > Image Mode** (Left/Right to cycle). Controls how images are downloaded, cached, and displayed to optimize memory usage and frame rate on the physical Playdate hardware.

| Mode | Behavior |
| :--- | :--- |
| **Render All** | Downloads and renders every image on the page in the background. Full visual fidelity at the cost of memory and initial load time. |
| **In-View Only** (default) | Downloads images only when they scroll into the visible viewport. Automatically evicts (frees) images from memory when they scroll off-screen with a 200px buffer. Best balance of visual quality and memory on device. |
| **On-Demand** | Shows a placeholder card for each image. Tapping an image opens a choice overlay: **(A) View Image** to download and render it, or **(B) Open Link** to follow the hyperlink. Loaded images can be tapped again to **Unload** them from memory. Maximum control over what gets downloaded. |
| **Hover** | Shows a `[Hover]` placeholder until the cursor (HTML mode) or link selector (Reader mode) moves over the image, then temporarily loads and renders it. The image is evicted from memory as soon as the cursor/selection moves away. Good for quick previews without long-term memory cost. |
| **Disabled** | Shows an `[Image Off]` placeholder for every image. No images are downloaded or rendered. Maximum frame rate on physical device for text-heavy browsing.

### Networking
- **Dual-Engine HTTP/HTTPS**: Native async socket communication using Playdate OS 2.7+ (`playdate.network.http` & `https`).
- **HTTP Redirect Handling**: Follows 301/302 redirects with depth tracking.
- **Chunked Transfer**: Supports chunked transfer-encoding.
- **Cookie Jar**: Session cookie persistence across requests.
- **Character Encoding Detection**: Scans `<meta charset>`, `<meta http-equiv="Content-Type">`, BOM markers, and chardet heuristics.

### User Interface
- **Chrome Bar**: URL display, SSL lock icon, page title, loading progress, battery level, reader/HTML mode toggle.
- **Address Bar**: On-screen keyboard for URL entry and search with autocomplete.
- **URL Hover Status Bar**: Shows destination URL when hovering links in HTML mode (like desktop browsers).
- **Link Preview**: Bottom HUD displays `-> https://...` for D-pad-selected links in reader mode.
- **Scrollbar**: Visual scrollbar with thumb position indicator.
- **Error Page**: Retry / Search / Home options on load failure.
- **Reader Mode Toggle**: Switch between article-distilled reader and full HTML rendering.

### Internal Pages
- `about:home` — Speed Dial start page
- `about:help` — Guide & keyboard shortcuts
- `about:acidtest` — HTML & image rendering test suite
- `about:blank` — Blank page

---

## Building & Sideloading

### 1. Build via Terminal
From the `CometBrowser` directory:
```bash
make
```
Or directly using `pdc`:
```bash
pdc Source CometBrowser.pdx
```

### 2. Run in Playdate Simulator
```bash
make sim
```
Or double-click `CometBrowser.pdx` or open it with the Simulator app.

### 3. Sideload to Physical Playdate Console
1. **Via Web Sideload**:
   - Go to [play.date/account/sideload](https://play.date/account/sideload).
   - Zip `CometBrowser.pdx` (e.g. `zip -r CometBrowser.pdx.zip CometBrowser.pdx`) and drag & drop it onto the webpage.
   - On your Playdate, navigate to **Settings > Games > Sideloaded** and download.
2. **Via USB Disk Mode**:
   - Connect Playdate via USB.
   - On device: **Settings > System > Reboot to Data Disk**.
   - Copy `CometBrowser.pdx` into the `Games/` directory on the Playdate USB drive.
   - Eject the disk.

---

## Project Architecture

```
CometBrowser/
├── CometBrowser.pdx/           # Compiled Playdate binary bundle
├── Makefile                    # Build and launch automation
├── README.md                   # This file
├── pdxinfo                     # Package metadata (bundle ID, version)
├── LICENSE
└── Source/                     # Full Lua codebase & assets
    ├── main.lua                # Main loop, state machine, input handling, form submission
    ├── pdxinfo                 # Package info (source copy)
    ├── icon.png                # 32x32 launcher icon
    │
    ├── core/                   # Foundational systems
    │   ├── constants.lua       # Screen geometry, view states, search engines, image rendering modes
    │   ├── url.lua             # URL parser, normalizer, relative resolver, search query builder
    │   ├── http_client.lua     # Async HTTP/HTTPS client, redirect following, connection pooling
    │   ├── storage.lua         # Persistent datastore for bookmarks, history, & settings (image mode, search engine, browse mode)
    │   ├── cookie_jar.lua      # Session cookie persistence across requests
    │   ├── encoding.lua        # Character encoding detection (charset, BOM, chardet)
    │   ├── tasks.lua           # Cooperative task scheduler for async operations
    │   └── logger.lua          # Debug logging (stripped in production builds)
    │
    ├── html/                   # HTML parsing & document model
    │   ├── tokenizer.lua       # HTML sanitizer & token parser
    │   ├── dom.lua             # DOM tree builder from token stream
    │   ├── document.lua        # Block hierarchy builder, form parsing, meta refresh detection
    │   ├── entities.lua        # HTML entity decoder (&amp; &#123; etc.)
    │   └── readability.lua     # Article distillation for reader mode
    │
    ├── render/                 # Layout & visual rendering
    │   ├── style.lua           # Typography, font metrics, Roobert font family
    │   ├── layout.lua          # Flow layout engine, line breaking, culling, image mode rendering, on-demand overlay, form element rendering
    │   ├── cloud_layout.lua    # Alternative layout engine for cloud/home page cards
    │   ├── link_manager.lua    # Link selection, hitbox tracking, hover detection
    │   ├── image_decoder.lua   # Image decode dispatcher, 1-bit dithering, caching, per-image evict
    │   └── decoders/           # Format-specific image decoders
    │       ├── svg.lua         # SVG path rendering (M/L/H/V/C/S/T/A/Z), transforms, styles
    │       ├── webp.lua        # WebP (VP8) lossy & lossless decoding
    │       ├── jpeg.lua        # Baseline JPEG DCT decoding
    │       ├── png.lua         # PNG interlaced/palette/truecolor decoding
    │       ├── gif.lua         # GIF animated & static frame decoding
    │       ├── bmp.lua         # BMP 1-bit & 8-bit bitmap decoding
    │       ├── ico.lua         # ICO favicon extraction
    │       ├── inflate.lua     # DEFLATE decompression (used by PNG, GIF, WebP)
    │       ├── dither.lua      # Ordered dithering for grayscale-to-monochrome
    │       ├── scale.lua       # Image scaling utilities
    │       └── webp_vp8_data.lua # VP8 bitstream tables for WebP decoding
    │
    ├── ui/                     # User interface components
    │   ├── chrome.lua          # Top toolbar (URL, SSL lock, page title, progress, battery)
    │   ├── address_bar.lua     # URL entry & search bar with on-screen keyboard
    │   ├── home_page.lua       # Speed dial grid start page
    │   ├── hud.lua             # Scrollbar, link preview bar, URL hover status bar
    │   ├── error_page.lua      # Error page with retry / search / home options
    │   ├── bookmarks_page.lua  # Bookmarks list & management
    │   ├── history_page.lua    # Browsing history viewer
    │   └── settings_page.lua   # Settings overlay (search engine, browse mode, image mode, invert crank, clear cookies)
    │
    ├── fonts/                  # Roobert font family (Playdate .fnt format)
    │   ├── Roobert-20-Medium.fnt
    │   ├── Roobert-11-Medium.fnt
    │   ├── Roobert-11-Medium-Halved.fnt
    │   ├── Roobert-11-Medium-Numerals.fnt
    │   ├── Roobert-11-Medium-extended.fnt
    │   ├── Roobert-11-Mono-Condensed.fnt
    │   ├── Roobert-10-Bold.fnt
    │   └── Roobert-10-Bold-Halved.fnt
    │
    ├── images/                 # UI images
    │   └── home_banner.png     # Home page banner graphic
    │
    └── assets/                 # Launcher cards & icons
        └── launcher/           # Playdate launcher card assets
```

---

## License

See [LICENSE](LICENSE) for details.
