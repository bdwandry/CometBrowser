# ☄️ CometBrowser for Playdate

**CometBrowser** is a fast, standalone, general-purpose web browser built specifically for the **Playdate handheld console** and **Playdate Simulator**. 

Unlike single-purpose feed readers, CometBrowser allows you to navigate to any web address (e.g. `wikipedia.org`, `news.ycombinator.com`, etc.), search the internet, click hyperlinks, render HTML headings, paragraphs, lists, blockquotes, code blocks, tables, and images with 1-bit monochrome graphics on the 400x240 sharp LCD screen.

---

## 🎮 Hardware Controls & Shortcuts

| Control | Action |
| :--- | :--- |
| **Physical Crank** | Smooth continuous vertical scrolling with kinetic inertia and acceleration. |
| **Ⓑ Button** | Open Address Bar & Web Search using the on-screen keyboard. |
| **Ⓐ Button** | Follow active focused hyperlink / Submit search / Select bookmark. |
| **D-Pad Up / Down** | Step scroll or cycle focus to previous / next link on the page. |
| **D-Pad Left / Right** | Jump half-page up / down or cycle horizontal links. |
| **Playdate System Menu** | Access **Home**, **Add Bookmark**, **Bookmarks Manager**, **History**, **Reader Mode**, and **Reload**. |

---

## 🚀 Key Features

1. **Anywhere URL & Search Navigation**:
   - Type any website address directly (`bryanwandrych.com`, `wikipedia.org`, `danluu.com`, etc.).
   - Type general search terms (e.g. `playdate games`, `retro computing`) to query fast text search engines (DuckDuckGo Lite, FrogFind, Wiby, Wikipedia).
2. **Dual-Engine Networking**:
   - Native HTTP & HTTPS asynchronous socket communication using Playdate OS 2.7+ (`playdate.network.http` & `https`).
   - Handles HTTP 301/302 redirects, chunked transfer buffers, and connection timeouts.
3. **HTML & Visual Flow Layout**:
   - Strips heavy JavaScript, stylesheets, and tracking payloads.
   - Renders `<h1>`–`<h6>`, `<p>`, `<a>`, `<ul>`/`<ol>`/`<li>`, `<blockquote>`, `<code>`, `<pre>`, `<hr>`, `<br>`, `<img>`, `<table>`.
4. **Interactive Hyperlinks**:
   - Links are underlined and dynamically tracked with bounding boxes.
   - D-Pad hops between links, while the bottom HUD displays the destination URL (`→ https://...`).
5. **Speed Dial Start Page & Bookmarks**:
   - Fast 2-column speed dial grid preloaded with essential sites.
   - Saved bookmarks and 50-item browsing history stored to disk via `playdate.datastore`.
6. **Internal Offline Pages**:
   - `about:home` (Speed Dial)
   - `about:help` (Guide & Shortcuts)
   - `about:acidtest` (HTML & image rendering test suite)
   - `about:blank` (Blank page)

---

## 🛠️ Building & Sideloading

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

## 📂 Project Architecture

```
CometBrowser/
├── CometBrowser.pdx/         # Compiled Playdate binary bundle (Ready to run/sideload)
├── Makefile                  # Build and launch automation
├── README.md                 # Full documentation
├── pdxinfo                   # Package metadata
└── Source/                   # Full Lua codebase & assets
    ├── main.lua              # Main loop, lifecycle, input, state machine
    ├── pdxinfo               # Package info
    ├── icon.png              # 32x32 launcher icon
    ├── core/
    │   ├── constants.lua     # Geometry, view states, default bookmarks
    │   ├── url.lua           # URL parser, normalizer, relative resolver
    │   ├── http_client.lua   # Async HTTP/HTTPS client & internal pages
    │   └── storage.lua       # Datastore for bookmarks & history
    ├── html/
    │   ├── entities.lua      # HTML entity decoder
    │   ├── tokenizer.lua     # HTML sanitizer & token parser
    │   └── document.lua      # DOM & block hierarchy builder
    ├── render/
    │   ├── style.lua         # Typography & font metrics (Roobert)
    │   ├── layout.lua        # Flow layout, line breaking, culling
    │   ├── link_manager.lua  # Link selection & hitbox manager
    │   └── image_decoder.lua # 1-bit image rendering
    ├── ui/
    │   ├── chrome.lua        # Top toolbar (URL, SSL lock, time, battery)
    │   ├── address_bar.lua   # URL & search bar with on-screen keyboard
    │   ├── home_page.lua     # Speed dial start page
    │   ├── hud.lua           # Scrollbar & link hover indicator
    │   ├── error_page.lua    # 404/Connection error page with retry
    │   ├── bookmarks_page.lua# Bookmarks list
    │   └── history_page.lua  # History viewer
    ├── fonts/                # High-legibility Playdate typography
    └── assets/               # Launcher cards & icons
```
