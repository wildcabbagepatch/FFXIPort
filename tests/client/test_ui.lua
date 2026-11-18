-- UI tests for FFXIPort 1.2.0 against a RECORDING ImGui mock (no rendering).
-- They check what FFXIPort asks ImGui to do: theme colours pushed, stacks
-- balanced, font sizes and paddings scaled, simulated layout widths, and the
-- behaviour of the theme dots, options popover, expansion filter, favourite
-- star and floating button, plus per-character settings. Visual appearance in
-- Ashita is NOT verified here.
-- GPL-3.0-only, (C) 2026 wildthing.
local root = arg and arg[1] or '.'
package.path = root .. '/tests/lib/?.lua;' .. package.path

local H  = require('harness')
local A  = require('ashita_mock')
local MK = require('imgui_mock')

MK.installGlobals()
local im, IS = MK.new()

A.install(root)
package.loaded['imgui'] = im

local catalog = require('ffxiport.catalog')
local config  = require('ffxiport.config')
local model   = require('ffxiport.model')
local travel  = require('ffxiport.travel')
local theme   = require('ffxiport.ui.theme')
local rows    = require('ffxiport.ui.rows')
local window  = require('ffxiport.ui.window')
local widgets = require('ffxiport.ui.widgets')

catalog.load()
config.init(catalog)

local zone = { zone = 230 }
function zone.current() return zone.zone end
function zone.inProgress() return false end

local protocol = { isBusy = function () return false end, now = function () return 1000 end,
    balances = function () return nil end }
local syncctl = { request = function () return true end }

travel.init({ catalog = catalog, model = model, config = config, protocol = protocol, zone = zone })
rows.init({ catalog = catalog, model = model, zone = zone, theme = theme, config = config })
window.init({ catalog = catalog, model = model, config = config, syncctl = syncctl, protocol = protocol,
    zone = zone, theme = theme, rows = rows, travel = travel, widgets = widgets })

-- A validated snapshot: Home Points 0, 9, 41 and 59, Survival Guide 6, Gate Crystal Holla unlocked.
local function snapshot()
    local offers = { default = { { cur = 'g', amount = 1000 }, { cur = 'c', amount = 100 } }, over = {} }
    local rp = { default = { { cur = 'g', amount = 1000 }, { cur = 'i', amount = 100 } }, over = {} }
    return {
        protocol = 'FPX/1', ch = 1, zone = 230, balances = { gil = 100000, cp = 5000, is = 5000 },
        unlock = { H = { [0] = true, [9] = true, [41] = true, [59] = true }, S = { [6] = true }, G = { [0] = true }, R = {} },
        counts = { H = 122, S = 98, G = 6, R = 7 },
        offers = { H = offers, S = offers, G = offers, R = rp },
    }
end

local now = 1000
local function frame(width)
    IS.windowWidth = width or IS.windowWidth
    MK.reset()
    now = now + 16
    window.render(now)
    assert(#IS.colors == 0, 'colour stack not balanced: ' .. #IS.colors)
    assert(#IS.vars == 0, 'style var stack not balanced: ' .. #IS.vars)
    assert(#IS.fonts == 0, 'font stack not balanced: ' .. #IS.fonts)
end

local function login(name)
    A.settings.switch(name)
    rows.clearCache()
end

local function fresh()
    login('Alpha')
    for _, k in ipairs({ 'theme', 'scale', 'expansion', 'button', 'only_usable' }) do
        config.set(k, config.DEFAULTS[k])
    end
    config.resetButtonPos()
    for _, key in ipairs(config.favourites()) do
        local tab, id = key:match('^(%a%a):(%d+)$')
        config.setFavourite(tab, tonumber(id), false)
    end
    model.clear()
    model.commitSync(snapshot(), now)
    window.close()
    window.resetSelection()
    IS.clicks, IS.hovers, IS.active, IS.popupOpen, IS.comboOpen = {}, {}, {}, {}, {}
    IS.dragDelta = { 0, 0 }
    IS.failFont, IS.failIn = nil, nil
    IS.windowWidth = 660
    rows.clearCache()
end

H.before = fresh

local function mainWindow() return MK.window('FFXIPort') end
local function itemsOf(windowName)
    local out = {}
    for _, it in ipairs(IS.items) do if it.window == windowName then out[#out + 1] = it end end
    return out
end
local function fontSizesPushed()
    local out = {}
    for _, c in ipairs(MK.calls('PushFont')) do out[#out + 1] = c[2] end
    return out
end

-----------------------------------------------------------------------------
H.describe('defaults and settings', function ()
    H.it('defaults: Classic, 100 %, All expansions, floating button hidden', function ()
        H.eq(config.get('theme'), 'classic'); H.eq(config.get('scale'), 100)
        H.eq(config.get('expansion'), 'all'); H.eq(config.get('button'), false)
        window.open()
        frame()
        H.eq(theme.current, 'classic'); H.eq(theme.scale, 1)
        H.eq(MK.window('ffxiport_float'), nil, 'no floating button window')
    end)

    H.it('invalid stored values fall back to safe defaults without errors', function ()
        local s = A.settings.file('Alpha')
        s.theme, s.scale, s.expansion, s.button, s.button_x, s.button_y = 'neon', 999, 'xyz', 'yes', 1e9, 'a'
        login('Beta'); login('Alpha') -- re-adopt the file: validation runs
        H.eq(config.get('theme'), 'classic'); H.eq(config.get('scale'), 200, 'clamped')
        H.eq(config.get('expansion'), 'all'); H.eq(config.get('button'), false)
        H.eq(config.buttonPos(), nil)
        window.open()
        frame()
    end)

    H.it('a settings file without the new keys (1.1.0) loads with defaults and keeps favourites', function ()
        local s = A.settings.file('Gamma') or {}
        A.settings.switch('Gamma')
        config.setFavourite('hp', 0, true)
        local file = A.settings.file('Gamma')
        file.theme, file.expansion = nil, nil
        login('Alpha'); login('Gamma')
        H.eq(config.get('theme'), 'classic'); H.eq(config.get('expansion'), 'all')
        H.truthy(config.isFavourite('hp', 0))
    end)

    H.it('settings are isolated per character and survive a reload', function ()
        config.set('theme', 'squad'); config.set('scale', 150); config.set('expansion', 'roz'); config.set('button', true)
        config.setButtonPos(321, 123)
        login('Beta')
        H.eq(config.get('theme'), 'classic'); H.eq(config.get('scale'), 100); H.eq(config.get('button'), false)
        config.set('theme', 'crimson')
        login('Alpha')
        H.eq(config.get('theme'), 'squad'); H.eq(config.get('scale'), 150); H.eq(config.get('expansion'), 'roz')
        H.eq(config.get('button'), true); H.eq(select(1, config.buttonPos()), 321)
        -- reload the settings module from the stored files (addon reload)
        package.loaded['ffxiport.config'] = nil
        local config2 = require('ffxiport.config')
        config2.init(catalog)
        H.eq(config2.get('theme'), 'squad'); H.eq(config2.get('scale'), 150)
        package.loaded['ffxiport.config'] = config
        config.init(catalog) -- give the library callback back to the instance under test
    end)
end)

-----------------------------------------------------------------------------
H.describe('themes', function ()
    H.it('Classic keeps the 1.1.0 colours and the native title bar', function ()
        window.open()
        frame()
        local w = mainWindow()
        H.eq(MK.colorAtBegin(w, 'ImGuiCol_WindowBg')[1], 0.105)
        H.eq(MK.colorAtBegin(w, 'ImGuiCol_TabSelected')[1], 0.53)
        H.eq(MK.colorAtBegin(w, 'ImGuiCol_TitleBg'), nil, 'no title-bar colour in Classic')
    end)

    H.it('clicking the dots switches the whole theme immediately and saves it', function ()
        window.open()
        frame()
        IS.clicks['ffxiport_theme_squad'] = true
        frame()
        H.eq(config.get('theme'), 'squad')
        frame()
        local w = mainWindow()
        H.eq(MK.colorAtBegin(w, 'ImGuiCol_WindowBg')[1], 0.067, 'Squad background #11131B')
        H.truthy(MK.colorAtBegin(w, 'ImGuiCol_TitleBg'), 'Squad title bar')
        IS.clicks['ffxiport_theme_crimson'] = true
        frame(); frame()
        H.eq(config.get('theme'), 'crimson')
        H.eq(MK.colorAtBegin(mainWindow(), 'ImGuiCol_TabSelected')[1], 0.50)
        IS.clicks['ffxiport_theme_classic'] = true
        frame(); frame()
        H.eq(config.get('theme'), 'classic')
        H.eq(MK.colorAtBegin(mainWindow(), 'ImGuiCol_TitleBg'), nil)
    end)

    H.it('every theme defines every colour the UI uses, with readable status colours', function ()
        local keys = { 'window', 'panel', 'header', 'button', 'border', 'text', 'gold', 'tabSel', 'rowSel',
            'muted', 'secondary', 'goGold', 'goText', 'ok', 'bad', 'dot' }
        local function lum(c) return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3] end
        for _, name in ipairs(theme.ORDER) do
            local t = theme.THEMES[name]
            for _, k in ipairs(keys) do H.truthy(type(t[k]) == 'table' and #t[k] >= 3, name .. '.' .. k) end
            for _, k in ipairs({ 'text', 'ok', 'bad', 'gold' }) do
                H.truthy(lum(t[k]) - lum(t.window) > 0.35, name .. ': ' .. k .. ' readable on the background')
            end
            H.truthy(math.abs(lum(t.goText) - lum(t.goGold)) > 0.3, name .. ': Teleport button text readable')
        end
    end)

    H.it('theme dots have tooltips and a ring marks the active one', function ()
        window.open()
        IS.hovers['ffxiport_theme_squad'] = true
        frame()
        local tips = table.concat(MK.calls('SetTooltip'), '|')
        H.truthy(tips:find('Squad theme', 1, true), tips)
        local rings = 0
        for _, d in ipairs(IS.drawn) do if d.fn == 'AddCircle' then rings = rings + 1 end end
        H.eq(rings, 1, 'exactly one active ring')
    end)

    H.it('themes never leak: all pushes are popped, also when rendering fails', function ()
        for _, name in ipairs(theme.ORDER) do
            config.set('theme', name)
            window.open()
            frame()
        end
        IS.failIn = 'FFXIPort'
        window.open()
        frame() -- asserts the stacks are empty
        H.falsy(window.isOpen(), 'window closed after the injected error')
    end)
end)

-----------------------------------------------------------------------------
H.describe('UI scaling', function ()
    H.it('options popover: + / - / 100 % change the scale live, within 70..200', function ()
        window.open()
        IS.clicks['ffxiport_options_btn'] = true
        frame()
        H.truthy(IS.popupOpen['ffxiport_options'])
        IS.clicks['ffxiport_scale_up'] = true; frame()
        H.eq(config.get('scale'), 110)
        for _ = 1, 15 do IS.clicks['ffxiport_scale_up'] = true; frame() end
        H.eq(config.get('scale'), 200, 'upper limit')
        IS.clicks['ffxiport_scale_reset'] = true; frame()
        H.eq(config.get('scale'), 100)
        for _ = 1, 10 do IS.clicks['ffxiport_scale_down'] = true; frame() end
        H.eq(config.get('scale'), 70, 'lower limit')
    end)

    H.it('fonts are scaled (PushFont base * scale) and paddings follow at 70 / 100 / 200 %', function ()
        for _, pct in ipairs({ 70, 100, 200 }) do
            config.set('scale', pct)
            window.open()
            frame()
            local sizes = fontSizesPushed()
            H.truthy(#sizes >= 1, 'font pushed')
            H.eq(sizes[1], 13 * pct / 100, 'font size at ' .. pct)
            local cons = MK.calls('SetNextWindowSizeConstraints')[1]
            H.eq(cons[1][1], 480 * pct / 100, 'min width scales')
        end
    end)

    H.it('the star and dots follow the scale (sized from the font)', function ()
        config.set('scale', 200)
        window.open()
        frame()
        local starSize, dotSize
        for _, c in ipairs(MK.calls('InvisibleButton')) do
            if c[1]:find('fav_') then starSize = c[2][1] end
            if c[1]:find('theme_') then dotSize = c[2][1] end
        end
        H.eq(starSize, 26); H.eq(dotSize, 26)
    end)

    H.it('controls fit or wrap at every scale and window width (no overflow)', function ()
        -- Worst case: search text (Clear button shown) and a selected
        -- destination (footer with payment choices and balances).
        window.select('hp', 9)
        for _, search in ipairs({ '', 'bastok' }) do
            window.setSearch(search)
            for _, pct in ipairs({ 70, 100, 200 }) do
                config.set('scale', pct)
                for _, width in ipairs({ 480 * pct / 100, 560 * pct / 100, 660, 900, 1600 }) do
                    if width >= 480 * pct / 100 then
                        window.open()
                        frame(width)
                        local right = width - 10 * pct / 100
                        local items = itemsOf('FFXIPort')
                        H.truthy(#items > 20, 'layout recorded')
                        for _, it in ipairs(items) do
                            H.truthy(it.x + it.w <= right + 0.5,
                                string.format('%s at %d%%/%dpx (search "%s") ends at %.1f > %.1f', it.id, pct, width, search, it.x + it.w, right))
                        end
                    end
                end
            end
        end
        window.setSearch('')
    end)

    H.it('if the font cannot be pushed, sizes still scale and the limitation is reported', function ()
        IS.failFont = true
        config.set('scale', 150)
        window.open()
        IS.clicks['ffxiport_options_btn'] = true
        frame()
        H.eq(theme.fontScaling, false)
        local texts = {}
        for _, c in ipairs(MK.calls('TextColored')) do texts[#texts + 1] = c[2] end
        H.truthy(table.concat(texts, '|'):find('Text size could not be scaled', 1, true))
        IS.failFont = nil
    end)
end)

-----------------------------------------------------------------------------
H.describe('expansion filter', function ()
    H.it('filters rows by expansion, keeps order, and combines with search and usable-only', function ()
        local all = rows.list('hp', '', false, now, 'all')
        local roz = rows.list('hp', '', false, now, 'roz')
        H.truthy(#roz > 0 and #roz < #all)
        local last = -1
        for _, item in ipairs(roz) do
            H.eq(item.row.exp, 'roz')
            H.truthy(item.row.id > last, 'catalogue order kept'); last = item.row.id
        end
        -- usable-only: unlocked HP 0 (base), 9 (base), 41 (Norg, roz), 59 (Ru'Aun, roz)
        local usableRoz = rows.list('hp', '', true, now, 'roz')
        H.eq(#usableRoz, 2)
        H.eq(usableRoz[1].row.id, 41); H.eq(usableRoz[2].row.id, 59)
        local usableBase = rows.list('hp', '', true, now, 'base')
        H.eq(#usableBase, 2)
        -- search narrows further
        local search = rows.list('hp', 'norg', false, now, 'roz')
        H.truthy(#search >= 1)
        for _, item in ipairs(search) do H.eq(item.row.zone, 252) end
        H.eq(#rows.list('hp', 'norg', false, now, 'base'), 0, 'empty combination')
    end)

    H.it('applies to Favorites without changing them; empty results are handled', function ()
        config.setFavourite('hp', 0, true); config.setFavourite('hp', 41, true)
        local favRoz = rows.list('fav', '', false, now, 'roz')
        H.eq(#favRoz, 1); H.eq(favRoz[1].row.id, 41)
        H.eq(#config.favourites(), 2, 'favourites unchanged')
        H.eq(#rows.list('fav', '', false, now, 'toau'), 0)
        H.eq(#rows.list('sp', '', false, now, 'toau'), 0, 'no ToAU Gate Crystals')
    end)

    H.it('combo selection is saved per character and shows counts in tab labels', function ()
        window.open()
        IS.comboOpen['ffxiport_expansion'] = true
        IS.clicks['ffxiport_exp_cop'] = true
        frame()
        H.eq(config.get('expansion'), 'cop')
        frame()
        local labels = table.concat(MK.calls('BeginTabItem'), '|')
        H.truthy(labels:find('Home Points %(%d+%)'), labels)
        local previews = MK.calls('BeginCombo')
        H.eq(previews[#previews][2], 'Chains of Promathia')
        login('Beta')
        H.eq(config.get('expansion'), 'all')
    end)

    H.it('does not modify unlock information', function ()
        local rev = model.revision()
        rows.list('hp', '', true, now, 'cop')
        H.eq(model.revision(), rev)
        H.eq(model.isUnlocked('hp', catalog.get('hp', 41)), true)
    end)
end)

-----------------------------------------------------------------------------
H.describe('favourite star', function ()
    H.it('outline when off, filled when on; click toggles and persists', function ()
        window.open()
        frame()
        local filled = 0
        for _, d in ipairs(IS.drawn) do if d.fn == 'AddTriangleFilled' then filled = filled + 1 end end
        H.eq(filled, 0, 'no favourite yet: outlines only')
        IS.clicks['ffxiport_fav_hp_0'] = true
        frame()
        H.truthy(config.isFavourite('hp', 0))
        frame()
        filled = 0
        for _, d in ipairs(IS.drawn) do if d.fn == 'AddTriangleFilled' then filled = filled + 1 end end
        H.eq(filled, 10, 'one filled star (10 triangles)')
        login('Beta'); login('Alpha')
        H.truthy(config.isFavourite('hp', 0), 'persists per character')
        IS.clicks['ffxiport_fav_hp_0'] = true
        frame()
        H.falsy(config.isFavourite('hp', 0))
    end)

    H.it('hover shows a preview and a tooltip; a star click never selects the row', function ()
        window.open()
        IS.hovers['ffxiport_fav_hp_9'] = true
        frame()
        H.truthy(table.concat(MK.calls('SetTooltip'), '|'):find('Add to favourites', 1, true))
        IS.clicks['ffxiport_fav_hp_9'] = true
        frame()
        H.eq(window.selection('hp'), nil)
    end)

    H.it('the empty Favorites text no longer refers to "*"', function ()
        H.falsy(window.FAV_EMPTY:find('*', 1, true))
    end)
end)

-----------------------------------------------------------------------------
H.describe('floating button', function ()
    local function float() return MK.window('ffxiport_float') end

    H.it('enabled from the options popover; hidden again when disabled', function ()
        window.open()
        IS.clicks['ffxiport_options_btn'] = true
        frame()
        IS.clicks['ffxiport_float_toggle'] = true
        frame()
        H.eq(config.get('button'), true)
        frame()
        H.truthy(float(), 'floating button window drawn')
        IS.clicks['ffxiport_float_toggle'] = true
        frame()
        frame()
        H.eq(config.get('button'), false); H.eq(float(), nil)
    end)

    H.it('click toggles the main window; works while the main window is closed', function ()
        config.set('button', true)
        frame()
        H.truthy(float()); H.falsy(window.isOpen())
        IS.clicks['ffxiport_float_btn'] = true
        frame()
        H.truthy(window.isOpen())
        IS.clicks['ffxiport_float_btn'] = true
        frame()
        H.falsy(window.isOpen())
    end)

    H.it('drag moves it, saves the position on release, and does not toggle', function ()
        config.set('button', true)
        frame()
        H.eq(float().pos[1], 40); H.eq(float().pos[2], 300)
        IS.active['ffxiport_float_btn'] = true
        IS.dragDelta = { 50, 20 }
        frame()
        frame()
        H.eq(float().pos[1], 90); H.eq(float().pos[2], 320)
        IS.active['ffxiport_float_btn'] = nil
        IS.clicks['ffxiport_float_btn'] = true -- the release after a drag
        frame()
        H.falsy(window.isOpen(), 'a drag is not a click')
        local x, y = config.buttonPos()
        H.eq(x, 90); H.eq(y, 320)
        login('Beta')
        H.eq(config.buttonPos(), nil, 'position is per character')
    end)

    H.it('does not take focus or navigation and is not saved to imgui.ini', function ()
        config.set('button', true)
        frame()
        local f = float().flags
        for _, flag in ipairs({ 'ImGuiWindowFlags_NoFocusOnAppearing', 'ImGuiWindowFlags_NoNav', 'ImGuiWindowFlags_NoSavedSettings', 'ImGuiWindowFlags_NoTitleBar' }) do
            -- flags are summed powers of two in the mock: test presence bitwise
            local v = MK.enumValue(flag)
            H.truthy(math.floor(f / v) % 2 == 1, flag)
        end
    end)

    H.it('scales with the UI and uses the theme for the button itself', function ()
        config.set('button', true); config.set('scale', 200); config.set('theme', 'squad')
        frame()
        H.eq(fontSizesPushed()[1], 26)
        H.eq(MK.colorAtBegin(float(), 'ImGuiCol_Button')[1], 0.169, 'Squad button colour #2B3041')
        H.eq(MK.varAtBegin(float(), 'ImGuiStyleVar_FrameRounding'), 8, 'rounding scales (4 px at 100 %)')
    end)

    -- rc.2 ------------------------------------------------------------------
    H.it('rc.2: no visible host window around the button, in every theme and scale', function ()
        config.set('button', true)
        for _, name in ipairs(theme.ORDER) do
            for _, pct in ipairs({ 70, 100, 200 }) do
                config.set('theme', name); config.set('scale', pct)
                frame()
                local f = float()
                local label = name .. ' ' .. pct .. '%'
                H.truthy(MK.hasFlag(f, 'ImGuiWindowFlags_NoBackground'), label .. ': NoBackground')
                H.truthy(MK.hasFlag(f, 'ImGuiWindowFlags_NoTitleBar'), label .. ': no title bar')
                H.eq(MK.colorAtBegin(f, 'ImGuiCol_WindowBg')[4], 0, label .. ': transparent window background')
                local pad = MK.varAtBegin(f, 'ImGuiStyleVar_WindowPadding')
                H.eq(pad[1], 0, label .. ': no horizontal padding'); H.eq(pad[2], 0, label .. ': no vertical padding')
                H.eq(MK.varAtBegin(f, 'ImGuiStyleVar_WindowBorderSize'), 0, label .. ': no window border')
                H.eq(MK.varAtBegin(f, 'ImGuiStyleVar_WindowMinSize')[1], 1, label .. ': no minimum-size margin')
                -- the button keeps its themed colour, text and rounding
                local b = MK.colorAtBegin(f, 'ImGuiCol_Button')
                local tb = theme.THEMES[name].button
                H.eq(b[1], tb[1], label .. ': themed button colour'); H.eq(b[4] or 1, tb[4] or 1)
                H.eq(MK.colorAtBegin(f, 'ImGuiCol_Text'), theme.THEMES[name].text, label .. ': themed text')
                H.truthy(MK.varAtBegin(f, 'ImGuiStyleVar_FrameRounding') > 0, label .. ': rounded')
                -- the only item in the window is the button, sized to its label
                local items = itemsOf('###ffxiport_float')
                H.eq(#items, 1, label .. ': only the button'); H.eq(items[1].id, 'ffxiport_float_btn')
            end
        end
    end)

    H.it('rc.2: the host-window style does not leak to the main window or other windows', function ()
        config.set('button', true)
        window.open()
        frame()
        local main = mainWindow()
        H.truthy(MK.colorAtBegin(main, 'ImGuiCol_WindowBg')[4] ~= 0, 'main window keeps its background')
        H.falsy(MK.hasFlag(main, 'ImGuiWindowFlags_NoBackground'))
        H.eq(MK.varAtBegin(main, 'ImGuiStyleVar_WindowBorderSize'), nil)
        H.eq(#IS.colors, 0); H.eq(#IS.vars, 0); H.eq(#IS.fonts, 0)
    end)

    H.it('rc.2: click toggles; drag never toggles; a click after a drag toggles again', function ()
        config.set('button', true)
        frame()
        IS.clicks['ffxiport_float_btn'] = true; frame()
        H.truthy(window.isOpen(), 'click opens')
        IS.active['ffxiport_float_btn'] = true; IS.dragDelta = { 30, 0 }
        frame(); frame()
        IS.active['ffxiport_float_btn'] = nil; IS.clicks['ffxiport_float_btn'] = true
        frame()
        H.truthy(window.isOpen(), 'drag release does not close')
        IS.dragDelta = { 0, 0 }
        IS.clicks['ffxiport_float_btn'] = true; frame()
        H.falsy(window.isOpen(), 'a normal click afterwards closes')
        IS.active['ffxiport_float_btn'] = true; IS.dragDelta = { 2, 1 } -- below the drag threshold
        frame()
        IS.active['ffxiport_float_btn'] = nil; IS.clicks['ffxiport_float_btn'] = true
        frame()
        H.truthy(window.isOpen(), 'a tiny movement still counts as a click')
    end)

    H.it('rc.2: switching characters without a reload uses each character\'s own position', function ()
        -- Beta: button on, saved at 200,150. Gamma: button on, never moved.
        login('Beta'); config.set('button', true); config.setButtonPos(200, 150)
        login('Gamma'); config.set('button', true); config.resetButtonPos()
        login('Alpha'); config.set('button', true)
        frame()
        IS.active['ffxiport_float_btn'] = true; IS.dragDelta = { 50, 20 }
        frame(); frame()
        IS.active['ffxiport_float_btn'] = nil
        frame()
        H.eq(select(1, config.buttonPos()), 90, 'Alpha saved')
        H.eq(float().pos[1], 90)
        login('Beta')           -- no addon reload
        frame()
        H.eq(float().pos[1], 200, 'Beta uses its own saved position'); H.eq(float().pos[2], 150)
        login('Gamma')
        frame()
        H.eq(float().pos[1], 40, 'Gamma has none: default'); H.eq(float().pos[2], 300)
        login('Alpha')
        frame()
        H.eq(float().pos[1], 90, 'back to Alpha'); H.eq(float().pos[2], 320)
        H.eq(select(1, config.buttonPos()), 90)
        login('Beta'); H.eq(select(1, config.buttonPos()), 200, 'Beta file untouched')
    end)

    H.it('rc.2: a drag in progress during a character switch is discarded', function ()
        login('Beta'); config.set('button', true); config.setButtonPos(200, 150)
        login('Alpha'); config.set('button', true)
        frame()
        IS.active['ffxiport_float_btn'] = true; IS.dragDelta = { 70, 70 }
        frame(); frame()
        login('Beta')            -- switch while the mouse is still down
        IS.active['ffxiport_float_btn'] = nil
        frame(); frame()
        H.eq(float().pos[1], 200, 'Beta not moved by Alpha\'s drag')
        H.eq(select(1, config.buttonPos()), 200, 'Beta file not overwritten')
        login('Alpha'); H.eq(config.buttonPos(), nil, 'Alpha never saved the unfinished drag')
    end)

    H.it('rc.2: logout and login transitions are safe', function ()
        config.set('button', true); config.setButtonPos(111, 222)
        frame()
        A.settings.switch(nil)   -- logout: library uses the defaults file
        frame()
        H.eq(float(), nil, 'logged out: defaults (button off)')
        login('Alpha')
        frame()
        H.eq(float().pos[1], 111); H.eq(float().pos[2], 222)
    end)
end)

-----------------------------------------------------------------------------
H.describe('rc.2: settings before login', function ()
    local function float() return MK.window('ffxiport_float') end
    local function loggedOut()
        A.settings.switch(nil)
        rows.clearCache()
    end

    H.it('a theme chosen before login does not override the character\'s saved theme', function ()
        config.set('theme', 'crimson'); config.set('scale', 120)
        loggedOut()
        window.open()
        frame()
        IS.clicks['ffxiport_theme_squad'] = true; frame()
        H.eq(theme.current, 'squad', 'pre-login choice applies for the session')
        login('Alpha')
        frame()
        H.eq(theme.current, 'crimson', 'saved theme restored at login')
        H.eq(theme.scale, 1.2, 'saved scale restored')
        H.eq(config.get('theme'), 'crimson', 'pre-login choice not saved to Alpha')
    end)

    H.it('pre-login scale, filter and floating-button choices do not leak either', function ()
        config.set('scale', 100); config.set('button', false); config.set('expansion', 'all')
        loggedOut()
        window.open()
        IS.clicks['ffxiport_options_btn'] = true; frame()
        IS.clicks['ffxiport_scale_up'] = true; frame()
        IS.clicks['ffxiport_float_toggle'] = true; frame()
        IS.comboOpen['ffxiport_expansion'] = true; IS.clicks['ffxiport_exp_toau'] = true; frame()
        IS.comboOpen['ffxiport_expansion'] = nil
        H.eq(window.pref('scale'), 110); H.eq(window.pref('button'), true); H.eq(window.pref('expansion'), 'toau')
        IS.active['ffxiport_float_btn'] = true; IS.dragDelta = { 300, 300 }
        frame(); frame()
        IS.active['ffxiport_float_btn'] = nil; frame()
        login('Alpha')
        frame()
        H.eq(window.pref('scale'), 100); H.eq(window.pref('button'), false); H.eq(window.pref('expansion'), 'all')
        H.eq(MK.window('ffxiport_float'), nil, 'button hidden as saved for Alpha')
        H.eq(config.buttonPos(), nil, 'pre-login drag not saved to Alpha')
    end)

    H.it('a new character (no saved theme) gets Classic, not the pre-login choice', function ()
        loggedOut()
        window.open()
        IS.clicks['ffxiport_theme_crimson'] = true; frame()
        login('Delta')
        frame()
        H.eq(theme.current, 'classic')
        H.eq(config.get('theme'), 'classic')
    end)

    H.it('changes after login are saved to the logged-in character', function ()
        loggedOut()
        frame()
        login('Alpha')
        window.open()
        IS.clicks['ffxiport_theme_squad'] = true; frame()
        H.eq(config.get('theme'), 'squad')
        login('Epsilon'); H.eq(config.get('theme'), 'classic', 'another character is unaffected')
        login('Alpha'); H.eq(config.get('theme'), 'squad')
    end)

    H.it('layer check: an override left in place is ignored while a character is logged in', function ()
        config.set('theme', 'crimson')
        loggedOut()
        window.setPref('theme', 'squad')      -- session-only override
        H.eq(window.pref('theme'), 'squad')
        A.settings.logged_in = true             -- logged in, no switch callback delivered
        H.eq(window.pref('theme'), config.get('theme'), 'character settings are authoritative')
        A.settings.switch('Alpha')
    end)

    H.it('layer check: after saving a drag, the saved position is used (no lingering runtime position)', function ()
        config.set('button', true)
        frame()
        IS.active['ffxiport_float_btn'] = true; IS.dragDelta = { 10, 10 }
        frame(); frame()
        IS.active['ffxiport_float_btn'] = nil; frame()
        H.eq(select(1, config.buttonPos()), 50)
        config.setButtonPos(300, 310) -- changed elsewhere (another session, the file)
        frame()
        H.eq(float().pos[1], 300, 'the saved value is what is drawn'); H.eq(float().pos[2], 310)
    end)

    H.it('favourites and saved settings survive the pre-login session', function ()
        config.setFavourite('hp', 9, true); config.set('theme', 'crimson')
        loggedOut()
        window.open()
        IS.clicks['ffxiport_theme_classic'] = true; frame()
        login('Alpha')
        H.truthy(config.isFavourite('hp', 9)); H.eq(config.get('theme'), 'crimson')
    end)

    H.it('reset position returns to the default', function ()
        config.set('button', true)
        config.setButtonPos(500, 500)
        window.open()
        IS.clicks['ffxiport_options_btn'] = true
        frame()
        IS.clicks['ffxiport_float_reset'] = true
        frame()
        H.eq(config.buttonPos(), nil)
        frame()
        H.eq(float().pos[1], 40)
    end)
end)

local ok = H.report('ui (mocked ImGui)')
os.exit(ok and 0 or 1)
