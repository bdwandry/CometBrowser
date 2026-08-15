# ☄️ CometBrowser for Playdate -- 

### Does this have AI All over it? (Yes it does)

**CometBrowser** is a fast, standalone, general-purpose web browser built specifically for the **Playdate handheld console** and **Playdate Simulator**. 

Unlike single-purpose feed readers, CometBrowser allows you to navigate to any web address (e.g. `wikipedia.org`, `news.ycombinator.com`, etc.), search the internet, click hyperlinks, render HTML headings, paragraphs, lists, blockquotes, code blocks, tables, and images with 1-bit monochrome graphics on the 400x240 sharp LCD screen.

---

## 🎮 Hardware Controls & Shortcuts

### Global

| Control | Action |
| :--- | :--- |
| **Physical Crank** | Scroll pages & list screens with kinetic inertia; moves the mouse cursor in HTML mode. |
| **Ⓐ Button** | Confirm / follow the focused link / activate a form input / open the selected item. |
| **Ⓑ Button** | Open the Address Bar (URL pre-filled when on a page); **release** to launch the on-screen keyboard. |
| **Ⓑ + Left** | **Back** in page history (press Left while the address-bar keyboard is armed). |
| **Ⓑ + Right** | **Forward** in page history (press Right while the address-bar keyboard is armed). |
| **Ⓐ + Left** | **Back** in page history (while on a page). |
| **Ⓐ + Right** | **Forward** in page history (while on a page). |

### Reader Mode (web page)

| Control | Action |
| :--- | :--- |
| **D-Pad Down** | Jump to the next link on the page (scroll down if none nearby). |
| **D-Pad Up** | Jump to the previous link on the page (scroll up if none nearby). |
| **Ⓐ** | Follow the focused link / activate a form input. |
| **Ⓑ** | Open the Address Bar pre-filled with the current URL. |
| **Crank** | Scroll with inertia. |

### HTML Mode (virtual mouse cursor)

| Control | Action |
| :--- | :--- |
| **D-Pad (hold)** | Move the mouse cursor in that direction. |
| **Crank** | Move the cursor up / down. |
| **Cursor near screen edge** | Auto-scroll the page. |
| **Ⓐ** | Left-click the hovered link / activate a form input. |
| **Ⓑ** | Open the Address Bar. |

### Home Page (Speed Dial)

| Control | Action |
| :--- | :--- |
| **D-Pad Up / Down** | Move between grid rows. |
| **D-Pad Left / Right** | Move between grid columns. |
| **Ⓐ** | Open the selected bookmark. |
| **Ⓑ** | Open the Address Bar & search. |
| **Crank** | Scroll the grid. |

### Loading Screen

| Control | Action |
| :--- | :--- |
| **Ⓑ** | Cancel the page load. |
| **Left** | Cancel the load and go **Back** in history. |

### Error Page

| Control | Action |
| :--- | :--- |
| **Left / Up** and **Right / Down** | Cycle through **Retry / Search / Home**. |
| **Ⓐ** | Confirm the highlighted option. |
| **Left** | Go **Back** in history. |

### Bookmarks & History Pages

| Control | Action |
| :--- | :--- |
| **D-Pad Up / Down** | Navigate the list. |
| **Ⓐ** | Open the selected entry. |
| **Ⓑ** | Close and return to the Home Page. |

### Playdate System Menu

Access **Home-Page**, **Display Mode** (toggle **Reader / HTML**), **Bookmarks**, **History**, and **Clear Cookies**.

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
