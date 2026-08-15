-- HTML Tree Builder for CometBrowser
-- Converts the flat token stream from the tokenizer into a lightweight DOM
-- tree so that nested structures (lists inside lists, tables, formatting
-- spans) survive intact. Implements a simplified version of the WHATWG tree
-- construction rules: void elements, raw-text/ignored subtrees, and the
-- common implied-end-tag rules (p, li, dt/dd, tr, td/th, option).

DOM = {}

local MAX_NODES = 6000

-- Void elements never have children or a closing tag.
local VOID = {
    area = true, base = true, br = true, col = true, embed = true,
    hr = true, img = true, input = true, link = true, meta = true,
    param = true, source = true, track = true, wbr = true
}

-- Elements whose entire subtree is inert / not rendered.
-- NOTE: noscript is deliberately absent: scripting is disabled in this
-- browser, so its fallback content must be parsed and rendered as markup
-- (per the HTML spec "scripting disabled" rules).
local SKIP_SUBTREE = {
    script = true, style = true, svg = true, math = true,
    template = true, datalist = true, map = true, head = true,
    title = true, meta = true, link = true, base = true, rp = true,
    selectedcontent = true
}

-- "Block" elements that imply the end of an open <p> when they start.
local BLOCK = {
    address = true, article = true, aside = true, blockquote = true,
    center = true, dd = true, details = true, dialog = true, dir = true,
    div = true, dl = true, dt = true, fieldset = true, figcaption = true,
    figure = true, footer = true, form = true, h1 = true, h2 = true,
    h3 = true, h4 = true, h5 = true, h6 = true, header = true,
    hgroup = true, hr = true, li = true, main = true, menu = true,
    nav = true, ol = true, p = true, pre = true, section = true,
    table = true, ul = true
}

-- Close any open <p> element (implied </p>).
local function closeOpenP(stack)
    for i = #stack, 2, -1 do
        if stack[i].tag == "p" then
            for j = #stack, i, -1 do table.remove(stack, j) end
            return true
        end
    end
    return false
end

-- Pop elements off the stack until (and including) the matching tag.
local function popToTag(stack, tag)
    for i = #stack, 2, -1 do
        if stack[i].tag == tag then
            for j = #stack, i, -1 do table.remove(stack, j) end
            return true
        end
    end
    return false
end

-- Prepare to open an <li>: close any open <li>, then make sure a list
-- container is in scope (otherwise attach the stray <li> at body level).
local function prepareListItem(stack)
    for i = #stack, 2, -1 do
        local t = stack[i].tag
        if t == "li" then
            for j = #stack, i, -1 do table.remove(stack, j) end
            break
        end
        if t == "ul" or t == "ol" or t == "menu" or t == "dir" then break end
    end
    for i = #stack, 2, -1 do
        local t = stack[i].tag
        if t == "ul" or t == "ol" or t == "menu" or t == "dir" then return end
    end
    while #stack > 1 do table.remove(stack) end
end

-- Prepare to open a <dt> or <dd>: close any open <dt>/<dd>, ensure a <dl>.
local function prepareDtDd(stack)
    for i = #stack, 2, -1 do
        local t = stack[i].tag
        if t == "dt" or t == "dd" then
            for j = #stack, i, -1 do table.remove(stack, j) end
            break
        end
        if t == "dl" then break end
    end
    for i = #stack, 2, -1 do
        if stack[i].tag == "dl" then return end
    end
    while #stack > 1 do table.remove(stack) end
end

-- Prepare to open a table row or table section (<tr>/<thead>/<tbody>/<tfoot>):
-- close any open cells/rows and require a table context. Returns false when
-- the element should be dropped (stray row outside a table).
local function prepareRow(stack)
    for i = #stack, 2, -1 do
        local t = stack[i].tag
        if t == "tr" or t == "td" or t == "th" then
            for j = #stack, i, -1 do table.remove(stack, j) end
            break
        end
        if t == "table" or t == "tbody" or t == "thead" or t == "tfoot" then break end
    end
    for i = #stack, 2, -1 do
        local t = stack[i].tag
        if t == "table" or t == "tbody" or t == "thead" or t == "tfoot" then return true end
    end
    return false
end

-- Prepare to open a <td>/<th>: close any open cell and require a <tr>.
local function prepareCell(stack)
    for i = #stack, 2, -1 do
        local t = stack[i].tag
        if t == "td" or t == "th" then
            for j = #stack, i, -1 do table.remove(stack, j) end
            break
        end
        if t == "tr" then break end
    end
    for i = #stack, 2, -1 do
        if stack[i].tag == "tr" then return true end
    end
    return false
end

-- Prepare to open an <option>: close any open <option>, require a <select>.
local function prepareOption(stack)
    for i = #stack, 2, -1 do
        local t = stack[i].tag
        if t == "option" then
            for j = #stack, i, -1 do table.remove(stack, j) end
            break
        end
        if t == "select" then break end
    end
    for i = #stack, 2, -1 do
        if stack[i].tag == "select" then return true end
    end
    return false
end

function DOM.build(tokens)
    local root = { kind = "element", tag = "#root", attrs = {}, children = {} }
    local stack = { root }
    local count = 0

    local function top() return stack[#stack] end

    local function append(node)
        if count >= MAX_NODES then return false end
        table.insert(top().children, node)
        count = count + 1
        return true
    end

    local skipDepth = 0
    local skipTag = nil

    for _, tok in ipairs(tokens or {}) do
        if count >= MAX_NODES then break end

        if skipDepth > 0 then
            if tok.type == "tag" and tok.isClosing and tok.name == skipTag then
                skipDepth = 0
            end

        elseif tok.type == "text" then
            append({ kind = "text", text = tok.content or "" })

        else
            local tag = tok.name or ""
            if tok.isClosing then
                if not VOID[tag] and not SKIP_SUBTREE[tag] then
                    popToTag(stack, tag)
                end
            else
                local attrs = tok.attrs or {}
                if SKIP_SUBTREE[tag] then
                    skipDepth = 1
                    skipTag = tag
                elseif VOID[tag] then
                    append({ kind = "element", tag = tag, attrs = attrs, children = {} })
                else
                    local doPush = true
                    if BLOCK[tag] then closeOpenP(stack) end
                    if tag == "li" then
                        prepareListItem(stack)
                    elseif tag == "dt" or tag == "dd" then
                        prepareDtDd(stack)
                    elseif tag == "tr" or tag == "thead" or tag == "tbody" or tag == "tfoot" then
                        doPush = prepareRow(stack)
                    elseif tag == "td" or tag == "th" then
                        doPush = prepareCell(stack)
                    elseif tag == "option" then
                        doPush = prepareOption(stack)
                    elseif tag == "a" then
                        -- Nested anchors are invalid; close the outer one.
                        popToTag(stack, "a")
                    end

                    if doPush then
                        local el = { kind = "element", tag = tag, attrs = attrs, children = {} }
                        append(el)
                        stack[#stack + 1] = el
                    end
                end
            end
        end
    end

    return root
end

return DOM
