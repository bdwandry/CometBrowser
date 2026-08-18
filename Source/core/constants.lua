-- CometBrowser Constants
Constants = {}

-- Display & Screen Geometry
Constants.SCREEN_WIDTH = 400
Constants.SCREEN_HEIGHT = 240
Constants.CHROME_HEIGHT = 24
Constants.CONTENT_Y = 24
Constants.CONTENT_HEIGHT = 216
Constants.CONTENT_WIDTH = 400
Constants.CONTENT_MARGIN = 8
Constants.CONTENT_TEXT_WIDTH = 384
Constants.SCROLLBAR_WIDTH = 5

-- View States
Constants.STATE_HOME = "home"
Constants.STATE_LOADING = "loading"
Constants.STATE_PAGE = "page"
Constants.STATE_ERROR = "error"
Constants.STATE_BOOKMARKS = "bookmarks"
Constants.STATE_HISTORY = "history"
Constants.STATE_SETTINGS = "settings"

-- 100% Pure On-Device Browsing Modes
Constants.MODE_READER   = "reader"
Constants.MODE_RAW_HTML = "html"
Constants.MODE_OPERA_DS = "ds"

-- Search Engines
Constants.SEARCH_ENGINES = {
    { name = "DuckDuckGo Lite", url = "https://html.duckduckgo.com/html/?q=" },
    { name = "FrogFind (Fast Text)", url = "http://frogfind.com/?q=" },
    { name = "Wiby (Classic Web)", url = "https://wiby.me/?q=" },
    { name = "Wikipedia Search", url = "https://en.wikipedia.org/wiki/Special:Search?search=" }
}

-- Default Start Page Speed Dials
Constants.DEFAULT_BOOKMARKS = {
    { title = "Google", url = "https://google.com", desc = "Search engine" },
    { title = "Playdate Developer", url = "https://play.date/dev", desc = "Documentation & SDK" },
    { title = "Hacker News", url = "https://news.ycombinator.com", desc = "Tech news & discussion" },
    { title = "Wikipedia", url = "https://en.wikipedia.org/wiki/Main_Page", desc = "Free encyclopedia" },
    { title = "DuckDuckGo Lite", url = "https://html.duckduckgo.com/html/", desc = "Fast private search" },
    { title = "FrogFind", url = "http://frogfind.com", desc = "Text web for vintage devices" },
    { title = "Wiby Search", url = "https://wiby.me", desc = "Search engine for simple web" },
    { title = "Motherfucking Website", url = "https://motherfuckingwebsite.com", desc = "Lightweight pure HTML" },
    { title = "Dan Luu's Blog", url = "https://danluu.com", desc = "Engineering essays & blogs" }
}

-- User-Agent
Constants.USER_AGENT = "Mozilla/5.0 (Playdate OS 2.7; 400x240; 1-bit Mono) CometBrowser/1.0"

-- Image Rendering Modes
Constants.IMAGE_MODE_ALL      = "all"
Constants.IMAGE_MODE_VIEWPORT = "viewport"
Constants.IMAGE_MODE_ONDEMAND = "ondemand"
Constants.IMAGE_MODE_HOVER    = "hover"
Constants.IMAGE_MODE_DISABLED = "disabled"

Constants.IMAGE_MODE_NAMES = {
    Constants.IMAGE_MODE_ALL,
    Constants.IMAGE_MODE_VIEWPORT,
    Constants.IMAGE_MODE_ONDEMAND,
    Constants.IMAGE_MODE_HOVER,
    Constants.IMAGE_MODE_DISABLED,
}

Constants.IMAGE_MODE_LABELS = {
    [Constants.IMAGE_MODE_ALL]      = "Render All",
    [Constants.IMAGE_MODE_VIEWPORT] = "In-View Only",
    [Constants.IMAGE_MODE_ONDEMAND] = "On-Demand",
    [Constants.IMAGE_MODE_HOVER]    = "Hover",
    [Constants.IMAGE_MODE_DISABLED] = "Disabled",
}
