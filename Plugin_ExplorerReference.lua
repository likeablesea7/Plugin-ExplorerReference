if not plugin then
	return
end

local Selection = game:GetService("Selection")
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")

--============================================================
-- Config / Theme
--============================================================

local INDENT = "  " -- 2 spaces per depth level
local INDENT_LEN = #INDENT
local NODE_TEXT_SIZE = 14
local DATA_KEY_BASE = "ExplorerReference_Data_v2" -- suffixed with GameId per experience
local DIFF_COLOR = "#FF6B6B" -- red for the appended detail

-- Monospace char width of the node font, used to align Mark guide lines.
local CHAR_WIDTH = 8
pcall(function()
	CHAR_WIDTH = TextService:GetTextSize("0000000000", NODE_TEXT_SIZE, Enum.Font.Code, Vector2.new(1e4, 1e4)).X / 10
end)

local THEME = {
	bg       = Color3.fromRGB(30, 30, 30),
	bar      = Color3.fromRGB(37, 37, 38),
	btn      = Color3.fromRGB(51, 51, 54),
	btnHover = Color3.fromRGB(66, 66, 70),
	text     = Color3.fromRGB(220, 220, 220),
	textDim  = Color3.fromRGB(140, 140, 140),
	header   = Color3.fromRGB(96, 160, 255),
	service  = Color3.fromRGB(120, 200, 140),
	rowSel      = Color3.fromRGB(38, 79, 120),
	rowLatest   = Color3.fromRGB(52, 104, 156), -- brighter: latest selected node
	rowHover    = Color3.fromRGB(45, 45, 48),
	border      = Color3.fromRGB(60, 60, 62),
	guide       = Color3.fromRGB(50, 50, 56), -- Mark vertical guide lines
	addBtn      = Color3.fromRGB(52, 130, 72), -- "+ Add Selection" stands out
	addBtnHover = Color3.fromRGB(64, 150, 86),
}

-- Horizontal offset (px, within a row) for a guide line at a given child depth.
local function guideX(depth)
	return math.floor(CHAR_WIDTH * (INDENT_LEN * (depth - 1) + 1))
end

-- Curated class-name abbreviations. Anything not here keeps its full name.
-- Values are unique so the generated key is unambiguous.
local CLASS_ABBREV = {
	ScreenGui = "SG", SurfaceGui = "SuG", BillboardGui = "BG",
	Frame = "F", ScrollingFrame = "SF", CanvasGroup = "CG",
	TextButton = "TB", TextLabel = "TL", TextBox = "TX",
	ImageButton = "IB", ImageLabel = "IL", ViewportFrame = "VF", VideoFrame = "VdF",
	Folder = "Fol", Configuration = "Cfg",
	LocalScript = "LS", Script = "Scr", ModuleScript = "MS",
	Part = "Prt", MeshPart = "MP", UnionOperation = "Un", Model = "Mdl",
	WedgePart = "WP", TrussPart = "TP", CornerWedgePart = "CWP",
	SpawnLocation = "SL", Seat = "St", VehicleSeat = "VS",
	Attachment = "Att", Bone = "Bn",
	Weld = "Wld", WeldConstraint = "WC", Motor6D = "M6D", Motor = "Mtr",
	HingeConstraint = "HgC", SpringConstraint = "SpC", RodConstraint = "RdC",
	RopeConstraint = "RpC", BallSocketConstraint = "BSC", PrismaticConstraint = "PmC",
	CylindricalConstraint = "CyC",
	RemoteEvent = "RE", RemoteFunction = "RF", BindableEvent = "BE", BindableFunction = "BF",
	UIListLayout = "UIL", UIGridLayout = "UIG", UITableLayout = "UIT", UIPageLayout = "UIPg",
	UIPadding = "UIP", UICorner = "UIC", UIGradient = "UIGr", UIStroke = "UIS",
	UIScale = "UISc", UIAspectRatioConstraint = "UIAR", UISizeConstraint = "UISz",
	Sound = "Snd", SoundGroup = "SGr",
	NumberValue = "NV", StringValue = "StV", BoolValue = "BV", IntValue = "IV",
	ObjectValue = "OV", Color3Value = "C3V", Vector3Value = "V3V", CFrameValue = "CFV",
	Camera = "Cam", Highlight = "Hl", Beam = "Bm", ParticleEmitter = "PE", Trail = "Trl",
	PointLight = "PL", SpotLight = "SpL", SurfaceLight = "SuL",
	ProximityPrompt = "PP", ClickDetector = "CD", Decal = "Dcl", Texture = "Txt",
	SpecialMesh = "SM", BlockMesh = "BM", CylinderMesh = "CM",
}

-- Per-ClassName color (hex, for RichText) applied to only the (ClassName) part
-- of a node's label. Anything not listed keeps the default text color.
local CLASS_COLOR = {
	ScrollingFrame = "#EA5A40", -- red (redder than Frame's orange)
	TextBox        = "#EA5A40", -- red (same as ScrollingFrame)
	TextButton     = "#45C46A", -- green
	ImageButton    = "#45C46A", -- green
	Frame          = "#F0913C", -- orange
	LocalScript    = "#86D9FF", -- light blue
	TextLabel      = "#6496F5", -- blue
	ImageLabel     = "#6496F5", -- blue
	ScreenGui      = "#6496F5", -- blue
	UIStroke       = "#6496F5", -- blue (same as ImageLabel/TextLabel)
	UIGradient     = "#6496F5", -- blue (same as ImageLabel/TextLabel)
}

--============================================================
-- State
--============================================================

-- group: { name, entries = { {inst, order, detail, padded, marked}... }, byInst = {[Instance]=entry}, counter }
local groups = {}
local activeIndex = 1
local multiSelect = false
local abbrevMode = false

-- Selection shown in the plugin, mirrored from Studio's Explorer selection.
local selection = {} -- ordered list of selected Instances (that are in the group)
local selectionSet = {} -- [Instance] = true
local latestInst = nil -- last selected; single-target actions use this

-- forward declarations
local refreshAll, refreshView, refreshTabs, refreshNameBox, save
local paintMulti, paintAbbrev, paintOverwrite, paintPad, paintMark
local applyLayout, applyHighlight

--============================================================
-- Safe accessors
--============================================================

local function safeParent(inst)
	local ok, p = pcall(function() return inst.Parent end)
	if ok then return p end
	return nil
end

local function safeName(inst)
	local ok, n = pcall(function() return inst.Name end)
	if ok then return n end
	return "?"
end

local function safeClass(inst)
	local ok, c = pcall(function() return inst.ClassName end)
	if ok then return c end
	return "?"
end

local function isValid(inst)
	local ok, res = pcall(function() return inst:IsDescendantOf(game) end)
	if ok then return res end
	return false
end

local function isService(inst)
	return safeParent(inst) == game
end

--============================================================
-- Labels / classes
--============================================================

-- The literal, full label a node reduces to: "Name (ClassName)" (service = "Name")
local function defaultLabelFull(inst)
	if isService(inst) then
		return safeName(inst)
	end
	return safeName(inst) .. " (" .. safeClass(inst) .. ")"
end

--============================================================
-- RichText / label helpers
--============================================================

local function escapeRich(s: string): string
	s = s:gsub("&", "&amp;")
	s = s:gsub("<", "&lt;")
	s = s:gsub(">", "&gt;")
	return s
end

-- Build a node's base label in plain and RichText forms (honoring abbrev mode).
-- Rich form keeps the Name in the default color and colors only the (ClassName).
-- Returns: plain, rich, isNode (false for services).
local function nodeLabels(inst)
	local nameStr = safeName(inst)
	if isService(inst) then
		return nameStr, escapeRich(nameStr), false
	end
	local cn = safeClass(inst)
	local shown = (abbrevMode and CLASS_ABBREV[cn]) or cn
	local plain = nameStr .. " (" .. shown .. ")"
	local classTxt = "(" .. escapeRich(shown) .. ")"
	local hex = CLASS_COLOR[cn]
	if hex then
		classTxt = '<font color="' .. hex .. '">' .. classTxt .. "</font>"
	end
	return plain, escapeRich(nameStr) .. " " .. classTxt, true
end

--============================================================
-- Model
--============================================================

local function activeGroup()
	return groups[activeIndex]
end

local function entryFor(group, inst)
	return group and group.byInst[inst]
end

local function addInstanceChain(group, inst)
	if not isValid(inst) or inst == game then return end
	local chain = {}
	local n = inst
	while n and n ~= game do
		table.insert(chain, 1, n)
		if safeParent(n) == game then break end
		n = safeParent(n)
	end
	for _, node in ipairs(chain) do
		if not group.byInst[node] then
			local e = { inst = node, order = group.counter, detail = nil }
			group.counter += 1
			table.insert(group.entries, e)
			group.byInst[node] = e
		end
	end
end

local function pruneStale(group)
	local kept = {}
	for _, e in ipairs(group.entries) do
		if isValid(e.inst) then
			table.insert(kept, e)
		else
			group.byInst[e.inst] = nil
		end
	end
	group.entries = kept
end

local function collectRoots(group)
	local roots = {}
	for _, e in ipairs(group.entries) do
		local p = safeParent(e.inst)
		if not (p and group.byInst[p]) then
			table.insert(roots, e)
		end
	end
	table.sort(roots, function(a, b) return a.order < b.order end)
	return roots
end

local function collectChildren(group, parentEntry)
	local kids = {}
	for _, e in ipairs(group.entries) do
		local p = safeParent(e.inst)
		if p and group.byInst[p] == parentEntry then
			table.insert(kids, e)
		end
	end
	table.sort(kids, function(a, b) return a.order < b.order end)
	return kids
end

-- Build display items for a group.
-- item: { kind="header"|"blank"|"service"|"node", copyText, displayText, rich, inst, depth, detached }
local function buildItems(group)
	local items = {}
	table.insert(items, { kind = "header", text = group.name })

	local function dfs(entry, depth)
		local inst = entry.inst
		if entry.padded then
			table.insert(items, { kind = "blank" }) -- Pad: empty line above this node
		end
		local prefix = string.rep(INDENT, depth)
		local svc = isService(inst)
		local copyText, displayText, rich
		local plainBase, richBase, isNode = nodeLabels(inst)

		if entry.detail and entry.detail ~= "" then
			copyText = prefix .. plainBase .. " " .. entry.detail
			displayText = prefix .. richBase .. " " .. '<font color="' .. DIFF_COLOR .. '">' .. escapeRich(entry.detail) .. "</font>"
			rich = true
		elseif isNode then
			copyText = prefix .. plainBase
			displayText = prefix .. richBase
			rich = true
		else
			copyText = prefix .. plainBase
			displayText = copyText
			rich = false
		end

		table.insert(items, {
			kind = svc and "service" or "node",
			copyText = copyText,
			displayText = displayText,
			rich = rich,
			inst = inst,
			depth = depth,
			detached = (depth == 0 and not svc),
		})
		for _, child in ipairs(collectChildren(group, entry)) do
			dfs(child, depth + 1)
		end
	end

	local roots = collectRoots(group)
	if #roots == 0 then
		table.insert(items, { kind = "blank" })
		table.insert(items, {
			kind = "node",
			copyText = "",
			displayText = "  (empty - select something in the Explorer and press Add Selection)",
			rich = false,
			inst = nil,
			depth = 0,
			detached = true,
		})
		return items
	end

	for idx, root in ipairs(roots) do
		-- separate main branches with a blank line (skip if the root is padded,
		-- since dfs already inserts one for it)
		if idx > 1 and not root.padded then table.insert(items, { kind = "blank" }) end
		dfs(root, 0)
	end

	-- Mark: for each marked parent, tag the rows spanning its direct children
	-- with a guide-line depth (drawn as a vertical line in createRow).
	for pIdx, it in ipairs(items) do
		local e = it.inst and group.byInst[it.inst]
		if e and e.marked and it.depth ~= nil then
			local d = it.depth
			local childDepth = d + 1
			local endIdx = #items
			for j = pIdx + 1, #items do
				local jt = items[j]
				if jt.inst and jt.depth ~= nil and jt.depth <= d then
					endIdx = j - 1
					break
				end
			end
			local firstIdx, lastIdx
			for k = pIdx + 1, endIdx do
				local kt = items[k]
				if kt.inst and kt.depth == childDepth then
					firstIdx = firstIdx or k
					lastIdx = k
				end
			end
			if firstIdx and lastIdx then
				for k = firstIdx, lastIdx do
					items[k].guides = items[k].guides or {}
					table.insert(items[k].guides, childDepth)
				end
			end
		end
	end

	return items
end

-- Distinct classes (with an abbreviation) used by nodes across the groups.
local function collectAbbrevKeys(groupList)
	local seen = {}
	local order = {}
	for _, g in ipairs(groupList) do
		for _, e in ipairs(g.entries) do
			if not isService(e.inst) then
				local cn = safeClass(e.inst)
				local ab = CLASS_ABBREV[cn]
				if ab and not seen[cn] then
					seen[cn] = ab
					table.insert(order, cn)
				end
			end
		end
	end
	table.sort(order)
	return order, seen
end

local function keyBlockText(groupList)
	local order, seen = collectAbbrevKeys(groupList)
	if #order == 0 then return "" end
	local lines = { "Key:" }
	for _, cn in ipairs(order) do
		table.insert(lines, "  " .. seen[cn] .. " = " .. cn)
	end
	return table.concat(lines, "\n")
end

local function groupToText(group)
	local items = buildItems(group)
	local lines = {}
	for _, it in ipairs(items) do
		if it.kind == "header" then
			table.insert(lines, "---- " .. it.text .. " " .. string.rep("-", math.max(4, 44 - #it.text)))
		elseif it.kind == "blank" then
			table.insert(lines, "")
		elseif it.inst then
			table.insert(lines, it.copyText)
		end
	end
	local text = table.concat(lines, "\n")
	if abbrevMode then
		local key = keyBlockText({ group })
		if key ~= "" then
			text = text .. "\n\n" .. key
		end
	end
	return text
end

local function allGroupsToText()
	local blocks = {}
	for _, g in ipairs(groups) do
		-- temporarily strip per-group key; add one combined key at the end
		local items = buildItems(g)
		local lines = {}
		for _, it in ipairs(items) do
			if it.kind == "header" then
				table.insert(lines, "---- " .. it.text .. " " .. string.rep("-", math.max(4, 44 - #it.text)))
			elseif it.kind == "blank" then
				table.insert(lines, "")
			elseif it.inst then
				table.insert(lines, it.copyText)
			end
		end
		table.insert(blocks, table.concat(lines, "\n"))
	end
	local text = table.concat(blocks, "\n\n\n")
	if abbrevMode then
		local key = keyBlockText(groups)
		if key ~= "" then
			text = text .. "\n\n\n" .. key
		end
	end
	return text
end

local function deleteSubtree(group, inst)
	local kept = {}
	for _, e in ipairs(group.entries) do
		local drop = (e.inst == inst)
		if not drop then
			local ok, isDesc = pcall(function() return e.inst:IsDescendantOf(inst) end)
			drop = ok and isDesc
		end
		if drop then
			group.byInst[e.inst] = nil
		else
			table.insert(kept, e)
		end
	end
	group.entries = kept
end

local function moveNode(group, inst, dir)
	local e = group.byInst[inst]
	if not e then return end
	local p = safeParent(inst)
	local pe = p and group.byInst[p]
	local siblings = pe and collectChildren(group, pe) or collectRoots(group)
	local idx
	for i, s in ipairs(siblings) do
		if s == e then idx = i break end
	end
	if not idx then return end
	local j = idx + dir
	if j < 1 or j > #siblings then return end
	local other = siblings[j]
	e.order, other.order = other.order, e.order
end

--============================================================
-- Persistence (per experience, keyed by GameId)
--============================================================

local function dataKey()
	return DATA_KEY_BASE .. "_" .. tostring(game.GameId)
end

local function pathOf(inst)
	local names = {}
	local n = inst
	while n and n ~= game do
		table.insert(names, 1, safeName(n))
		if safeParent(n) == game then break end
		n = safeParent(n)
	end
	if #names == 0 then return nil end
	return names
end

local function resolvePath(path)
	local n = game
	for _, name in ipairs(path) do
		local ok, child = pcall(function() return n:FindFirstChild(name) end)
		if not ok or not child then return nil end
		n = child
	end
	return n
end

save = function()
	local data = { active = activeIndex, abbrev = abbrevMode, groups = {} }
	for _, g in ipairs(groups) do
		local gg = { name = g.name, nodes = {} }
		for _, e in ipairs(g.entries) do
			local path = pathOf(e.inst)
			if path then
				table.insert(gg.nodes, { path = path, order = e.order, detail = e.detail, padded = e.padded, marked = e.marked })
			end
		end
		table.insert(data.groups, gg)
	end
	pcall(function()
		plugin:SetSetting(dataKey(), HttpService:JSONEncode(data))
	end)
end

local function newGroup(silent)
	local g = { name = "Group " .. (#groups + 1), entries = {}, byInst = {}, counter = 0 }
	table.insert(groups, g)
	activeIndex = #groups
	if not silent then
		save()
		refreshAll()
	end
	return g
end

local function load()
	local raw = plugin:GetSetting(dataKey())
	if not raw then return end
	local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
	if not ok or type(data) ~= "table" or type(data.groups) ~= "table" then return end

	groups = {}
	for _, gg in ipairs(data.groups) do
		local g = { name = gg.name or "Group", entries = {}, byInst = {}, counter = 0 }
		local nodes = gg.nodes or {}
		table.sort(nodes, function(a, b) return (a.order or 0) < (b.order or 0) end)
		for _, nd in ipairs(nodes) do
			local inst = nd.path and resolvePath(nd.path)
			if inst and not g.byInst[inst] then
				local e = { inst = inst, order = nd.order or g.counter, detail = nd.detail, padded = nd.padded, marked = nd.marked }
				table.insert(g.entries, e)
				g.byInst[inst] = e
				g.counter = math.max(g.counter, (nd.order or 0) + 1)
			end
		end
		table.insert(groups, g)
	end
	activeIndex = data.active or 1
	if activeIndex < 1 or activeIndex > #groups then activeIndex = 1 end
	abbrevMode = data.abbrev == true
end

--============================================================
-- Dock widget
--============================================================

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float,
	false, -- start closed
	false, -- do not override the previously saved enabled state
	470, 620, -- default float size
	320, 320 -- minimum size
)

-- Prefer the non-deprecated Async creator; fall back if this Studio lacks it.
local widget
pcall(function()
	widget = plugin:CreateDockWidgetPluginGuiAsync("ExplorerReferencePanel", widgetInfo)
end)
if not widget then
	widget = plugin:CreateDockWidgetPluginGui("ExplorerReferencePanel", widgetInfo)
end
widget.Title = "Explorer Reference"

-- Clear leftover children if this plugin re-ran in the same session (the
-- widget itself is persistent across reloads).
for _, c in ipairs(widget:GetChildren()) do
	c:Destroy()
end

-- Root frame filling the widget; everything else parents into this.
local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.new(1, 0, 1, 0)
content.BackgroundColor3 = THEME.bg
content.BorderSizePixel = 0
content.Parent = widget

--============================================================
-- Widget-building helpers
--============================================================

local function createBtnVisual(parent, text)
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.BackgroundColor3 = THEME.btn
	b.BorderSizePixel = 0
	b.Size = UDim2.new(0, 0, 1, -6)
	b.AutomaticSize = Enum.AutomaticSize.X
	b.Font = Enum.Font.Gotham
	b.TextSize = 13
	b.TextColor3 = THEME.text
	b.Text = text
	b.Name = "Btn_" .. text
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = b
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = b
	b.Parent = parent
	return b
end

local function makeButton(parent, text, cb, bgColor, hoverColor)
	local b = createBtnVisual(parent, text)
	local base = bgColor or THEME.btn
	local hover = hoverColor or THEME.btnHover
	b.BackgroundColor3 = base
	b.MouseEnter:Connect(function() b.BackgroundColor3 = hover end)
	b.MouseLeave:Connect(function() b.BackgroundColor3 = base end)
	b.MouseButton1Click:Connect(function()
		local ok, err = pcall(cb)
		if not ok then warn("[ExplorerReference] " .. tostring(err)) end
	end)
	return b
end

-- A toggle button that keeps its "on" color even when the cursor leaves.
local function makeToggle(parent, text, isOn, onClick)
	local b = createBtnVisual(parent, text)
	local function paint()
		b.BackgroundColor3 = isOn() and THEME.rowSel or THEME.btn
	end
	b.MouseEnter:Connect(function()
		if not isOn() then b.BackgroundColor3 = THEME.btnHover end
	end)
	b.MouseLeave:Connect(paint)
	b.MouseButton1Click:Connect(function()
		local ok, err = pcall(onClick)
		if not ok then warn("[ExplorerReference] " .. tostring(err)) end
		paint()
	end)
	paint()
	return b, paint
end

local function makeStrip(parent, yPos, height)
	local strip = Instance.new("ScrollingFrame")
	strip.BackgroundColor3 = THEME.bar
	strip.BorderSizePixel = 0
	strip.Size = UDim2.new(1, 0, 0, height)
	strip.Position = UDim2.new(0, 0, 0, yPos)
	strip.ScrollBarThickness = 4
	strip.ScrollingDirection = Enum.ScrollingDirection.X
	strip.AutomaticCanvasSize = Enum.AutomaticSize.X
	strip.CanvasSize = UDim2.new(0, 0, 0, 0)
	strip.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 4)
	layout.Parent = strip
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = strip
	return strip
end

--============================================================
-- Layout
--============================================================

local actionRow = makeStrip(content, 4, 28)
local actionRow2 = makeStrip(content, 34, 28)
local tabRow = makeStrip(content, 64, 28)

-- Group-name row: editable name box (rename) + Del Group
local nameRow = Instance.new("Frame")
nameRow.BackgroundColor3 = THEME.bar
nameRow.BorderSizePixel = 0
nameRow.Position = UDim2.new(0, 0, 0, 94)
nameRow.Size = UDim2.new(1, 0, 0, 24)
nameRow.Parent = content

local nameBox = Instance.new("TextBox")
nameBox.BackgroundColor3 = THEME.btn
nameBox.BorderSizePixel = 0
nameBox.Position = UDim2.new(0, 6, 0, 3)
nameBox.Size = UDim2.new(1, -86, 0, 18)
nameBox.Font = Enum.Font.Gotham
nameBox.TextSize = 12
nameBox.TextColor3 = THEME.header
nameBox.TextXAlignment = Enum.TextXAlignment.Left
nameBox.ClearTextOnFocus = false
nameBox.Text = ""
nameBox.PlaceholderText = "group name"
nameBox.Parent = nameRow
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 4)
	c.Parent = nameBox
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, 6)
	p.Parent = nameBox
end

local delGroupBtn = Instance.new("TextButton")
delGroupBtn.AnchorPoint = Vector2.new(1, 0)
delGroupBtn.Position = UDim2.new(1, -6, 0, 3)
delGroupBtn.Size = UDim2.new(0, 72, 0, 18)
delGroupBtn.BackgroundColor3 = THEME.btn
delGroupBtn.BorderSizePixel = 0
delGroupBtn.Font = Enum.Font.Gotham
delGroupBtn.TextSize = 12
delGroupBtn.TextColor3 = THEME.text
delGroupBtn.Text = "Del Group"
delGroupBtn.AutoButtonColor = false
delGroupBtn.Parent = nameRow
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 4)
	c.Parent = delGroupBtn
end
delGroupBtn.MouseEnter:Connect(function() delGroupBtn.BackgroundColor3 = THEME.btnHover end)
delGroupBtn.MouseLeave:Connect(function() delGroupBtn.BackgroundColor3 = THEME.btn end)

-- Body (node list)
local body = Instance.new("ScrollingFrame")
body.BackgroundColor3 = THEME.bg
body.BorderSizePixel = 0
body.Position = UDim2.new(0, 0, 0, 122)
body.Size = UDim2.new(1, 0, 1, -122)
body.ScrollBarThickness = 6
body.ScrollingDirection = Enum.ScrollingDirection.XY
body.AutomaticCanvasSize = Enum.AutomaticSize.XY
body.CanvasSize = UDim2.new(0, 0, 0, 0)
body.Parent = content
do
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = body
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.Parent = body
end

-- Key panel (bottom, only when abbreviation mode is on)
local KEY_PANEL_H = 104
local keyPanel = Instance.new("ScrollingFrame")
keyPanel.BackgroundColor3 = THEME.bar
keyPanel.BorderSizePixel = 0
keyPanel.AnchorPoint = Vector2.new(0, 1)
keyPanel.Position = UDim2.new(0, 0, 1, 0)
keyPanel.Size = UDim2.new(1, 0, 0, KEY_PANEL_H)
keyPanel.ScrollBarThickness = 4
keyPanel.ScrollingDirection = Enum.ScrollingDirection.Y
keyPanel.AutomaticCanvasSize = Enum.AutomaticSize.Y
keyPanel.CanvasSize = UDim2.new(0, 0, 0, 0)
keyPanel.Visible = false
keyPanel.Parent = content

local keyLabel = Instance.new("TextLabel")
keyLabel.BackgroundTransparency = 1
keyLabel.Size = UDim2.new(1, -12, 0, 0)
keyLabel.AutomaticSize = Enum.AutomaticSize.Y
keyLabel.Position = UDim2.new(0, 8, 0, 4)
keyLabel.Font = Enum.Font.Code
keyLabel.TextSize = 13
keyLabel.TextColor3 = THEME.textDim
keyLabel.TextXAlignment = Enum.TextXAlignment.Left
keyLabel.TextYAlignment = Enum.TextYAlignment.Top
keyLabel.Text = ""
keyLabel.Parent = keyPanel

applyLayout = function()
	if abbrevMode then
		keyPanel.Visible = true
		body.Size = UDim2.new(1, 0, 1, -(122 + KEY_PANEL_H + 4))
	else
		keyPanel.Visible = false
		body.Size = UDim2.new(1, 0, 1, -122)
	end
end

--============================================================
-- Overlays (copy + overwrite editor)
--============================================================

local function makeOverlay()
	local o = Instance.new("Frame")
	o.BackgroundColor3 = THEME.bg
	o.BorderSizePixel = 0
	o.Active = true -- sink input so the node list underneath isn't clickable
	o.Position = UDim2.new(0, 0, 0, 0)
	o.Size = UDim2.new(1, 0, 1, 0)
	o.Visible = false
	o.ZIndex = 50
	o.Parent = content
	return o
end

-- Copy overlay
local copyOverlay = makeOverlay()
local copyInfo = Instance.new("TextLabel")
copyInfo.BackgroundColor3 = THEME.bar
copyInfo.BorderSizePixel = 0
copyInfo.Size = UDim2.new(1, 0, 0, 26)
copyInfo.Font = Enum.Font.Gotham
copyInfo.TextSize = 12
copyInfo.TextColor3 = THEME.text
copyInfo.Text = "  Press Ctrl+C to copy, then Close."
copyInfo.TextXAlignment = Enum.TextXAlignment.Left
copyInfo.ZIndex = 51
copyInfo.Parent = copyOverlay

local copyClose = createBtnVisual(copyOverlay, "Close")
copyClose.AnchorPoint = Vector2.new(1, 0)
copyClose.Position = UDim2.new(1, -6, 0, 2)
copyClose.Size = UDim2.new(0, 0, 0, 22)
copyClose.ZIndex = 51
copyClose.MouseButton1Click:Connect(function() copyOverlay.Visible = false end)

-- Scroll container: clips text below the top bar and shows scrollbars.
local copyScroll = Instance.new("ScrollingFrame")
copyScroll.BackgroundColor3 = THEME.bg
copyScroll.BorderColor3 = THEME.border
copyScroll.BorderSizePixel = 1
copyScroll.Position = UDim2.new(0, 0, 0, 26)
copyScroll.Size = UDim2.new(1, 0, 1, -26)
copyScroll.ClipsDescendants = true
copyScroll.ScrollBarThickness = 8
copyScroll.ScrollingDirection = Enum.ScrollingDirection.XY
copyScroll.AutomaticCanvasSize = Enum.AutomaticSize.XY
copyScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
copyScroll.ZIndex = 51
copyScroll.Parent = copyOverlay

local copyBox = Instance.new("TextBox")
copyBox.BackgroundTransparency = 1
copyBox.BorderSizePixel = 0
copyBox.Position = UDim2.new(0, 0, 0, 0)
copyBox.Size = UDim2.new(0, 0, 0, 0)
copyBox.AutomaticSize = Enum.AutomaticSize.XY
copyBox.Font = Enum.Font.Code
copyBox.TextSize = 14
copyBox.TextColor3 = THEME.text
copyBox.TextXAlignment = Enum.TextXAlignment.Left
copyBox.TextYAlignment = Enum.TextYAlignment.Top
copyBox.MultiLine = true
copyBox.ClearTextOnFocus = false
copyBox.TextEditable = true
copyBox.TextWrapped = false
copyBox.Text = ""
copyBox.ZIndex = 51
copyBox.Parent = copyScroll
do
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, 6)
	p.PaddingTop = UDim.new(0, 4)
	p.PaddingRight = UDim.new(0, 10)
	p.PaddingBottom = UDim.new(0, 10)
	p.Parent = copyBox
end

local function showCopy(text)
	copyBox.Text = text
	copyScroll.CanvasPosition = Vector2.new(0, 0)
	copyOverlay.Visible = true
	task.defer(function()
		copyBox:CaptureFocus()
		copyBox.CursorPosition = #copyBox.Text + 1
		copyBox.SelectionStart = 1
	end)
end

-- Overwrite editor overlay: appends an editable "detail" to a node's label.
-- The base label stays unchangeable (and still abbreviates); the detail you
-- type is appended and shown red in the list.
local owOverlay = makeOverlay()

local owInfo = Instance.new("TextLabel")
owInfo.BackgroundColor3 = THEME.bar
owInfo.BorderSizePixel = 0
owInfo.Size = UDim2.new(1, 0, 0, 30)
owInfo.Font = Enum.Font.GothamMedium
owInfo.TextSize = 13
owInfo.TextColor3 = THEME.text
owInfo.Text = "   Overwrite - add detail to a node"
owInfo.TextXAlignment = Enum.TextXAlignment.Left
owInfo.ZIndex = 51
owInfo.Parent = owOverlay

-- Read-only base label the detail is attached to (cannot be edited)
local owBaseLabel = Instance.new("TextLabel")
owBaseLabel.BackgroundColor3 = THEME.bg
owBaseLabel.BorderColor3 = THEME.border
owBaseLabel.BorderSizePixel = 1
owBaseLabel.Position = UDim2.new(0, 8, 0, 40)
owBaseLabel.Size = UDim2.new(1, -16, 0, 24)
owBaseLabel.Font = Enum.Font.Code
owBaseLabel.TextSize = 14
owBaseLabel.TextColor3 = THEME.textDim
owBaseLabel.TextXAlignment = Enum.TextXAlignment.Left
owBaseLabel.Text = ""
owBaseLabel.ZIndex = 51
owBaseLabel.Parent = owOverlay
do
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, 6)
	p.Parent = owBaseLabel
end

-- Editable detail (appended to the base; shown red)
local owBox = Instance.new("TextBox")
owBox.BackgroundColor3 = THEME.bg
owBox.BorderColor3 = THEME.border
owBox.BorderSizePixel = 1
owBox.Position = UDim2.new(0, 8, 0, 70)
owBox.Size = UDim2.new(1, -16, 0, 26)
owBox.Font = Enum.Font.Code
owBox.TextSize = 14
owBox.TextColor3 = Color3.fromRGB(255, 107, 107)
owBox.PlaceholderText = "additional detail, e.g. (Offset: -Y , 0)"
owBox.PlaceholderColor3 = THEME.textDim
owBox.TextXAlignment = Enum.TextXAlignment.Left
owBox.ClearTextOnFocus = false
owBox.TextEditable = true
owBox.Text = ""
owBox.ZIndex = 51
owBox.Parent = owOverlay
do
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, 6)
	p.Parent = owBox
end

local owTarget = nil -- Instance currently being edited

local owApply = createBtnVisual(owOverlay, "Apply")
owApply.Position = UDim2.new(0, 8, 0, 106)
owApply.Size = UDim2.new(0, 0, 0, 24)
owApply.ZIndex = 51

local owRemove = createBtnVisual(owOverlay, "Remove")
owRemove.Position = UDim2.new(0, 80, 0, 106)
owRemove.Size = UDim2.new(0, 0, 0, 24)
owRemove.ZIndex = 51

local owCancel = createBtnVisual(owOverlay, "Cancel")
owCancel.Position = UDim2.new(0, 170, 0, 106)
owCancel.Size = UDim2.new(0, 0, 0, 24)
owCancel.ZIndex = 51

--============================================================
-- Refresh
--============================================================

local bodyRows = {}

-- Recompute the plugin selection from Studio's Explorer selection (only nodes
-- that are actually in this group). The last one is treated as "latest".
local function computeSelectionFromStudio(group)
	selection = {}
	for _, inst in ipairs(Selection:Get()) do
		if group.byInst[inst] then
			table.insert(selection, inst)
		end
	end
	selectionSet = {}
	for _, inst in ipairs(selection) do
		selectionSet[inst] = true
	end
	latestInst = selection[#selection] -- may be nil
end

-- Paint every row's background from the current selection (latest = brighter).
applyHighlight = function()
	for _, row in ipairs(bodyRows) do
		if row.inst and row.inst == latestInst then
			row.button.BackgroundTransparency = 0
			row.button.BackgroundColor3 = THEME.rowLatest
		elseif row.inst and selectionSet[row.inst] then
			row.button.BackgroundTransparency = 0
			row.button.BackgroundColor3 = THEME.rowSel
		else
			row.button.BackgroundTransparency = 1
		end
	end
	if paintOverwrite then paintOverwrite() end
	if paintPad then paintPad() end
	if paintMark then paintMark() end
end

local function clearBody()
	bodyRows = {}
	for _, child in ipairs(body:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end
end

-- Draw Mark guide lines (thin full-height vertical segments) inside a row.
local function addGuides(rowObj, guides)
	if not guides then return end
	for _, depth in ipairs(guides) do
		local line = Instance.new("Frame")
		line.Name = "Guide"
		line.BackgroundColor3 = THEME.guide
		line.BorderSizePixel = 0
		line.Size = UDim2.new(0, 1, 1, 0)
		line.Position = UDim2.new(0, guideX(depth), 0, 0)
		-- Above the opaque row/body background (ZIndex 1) so it stays visible in
		-- both Global and Sibling ZIndexBehavior; it sits in the indent gap, so
		-- rendering over the text layer never overlaps any glyphs.
		line.ZIndex = 3
		line.Parent = rowObj
	end
end

local function createRow(item, order)
	if item.kind == "blank" then
		local spacer = Instance.new("Frame")
		spacer.BackgroundTransparency = 1
		spacer.Size = UDim2.new(1, 0, 0, 8)
		spacer.LayoutOrder = order
		spacer.Parent = body
		addGuides(spacer, item.guides)
		return
	end

	if item.kind == "header" then
		local h = Instance.new("TextLabel")
		h.BackgroundTransparency = 1
		h.Size = UDim2.new(1, 0, 0, 22)
		h.AutomaticSize = Enum.AutomaticSize.X
		h.Font = Enum.Font.GothamBold
		h.TextSize = 14
		h.TextColor3 = THEME.header
		h.TextXAlignment = Enum.TextXAlignment.Left
		h.Text = "-- " .. item.text .. " " .. string.rep("-", 20)
		h.LayoutOrder = order
		h.Parent = body
		return
	end

	local btn = Instance.new("TextButton")
	btn.AutoButtonColor = false
	btn.BackgroundTransparency = 1
	btn.BackgroundColor3 = THEME.rowSel
	btn.BorderSizePixel = 0
	btn.Size = UDim2.new(1, 0, 0, 18)
	btn.AutomaticSize = Enum.AutomaticSize.X
	btn.Font = Enum.Font.Code
	btn.TextSize = 14
	btn.TextXAlignment = Enum.TextXAlignment.Left
	btn.LayoutOrder = order
	if item.detached then
		-- orphaned node / empty-group placeholder: dim, no class coloring
		btn.RichText = false
		btn.Text = item.inst and item.copyText or item.displayText
		btn.TextColor3 = THEME.textDim
	else
		-- Name in default color; only the (ClassName) is colored (via RichText)
		btn.RichText = item.rich
		btn.Text = item.displayText
		btn.TextColor3 = THEME.text
	end
	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = btn

	if item.inst then
		local inst = item.inst
		btn.MouseEnter:Connect(function()
			if inst ~= latestInst and not selectionSet[inst] then
				btn.BackgroundTransparency = 0
				btn.BackgroundColor3 = THEME.rowHover
			end
		end)
		btn.MouseLeave:Connect(function()
			if inst == latestInst then
				btn.BackgroundTransparency = 0
				btn.BackgroundColor3 = THEME.rowLatest
			elseif selectionSet[inst] then
				btn.BackgroundTransparency = 0
				btn.BackgroundColor3 = THEME.rowSel
			else
				btn.BackgroundTransparency = 1
			end
		end)
		btn.MouseButton1Click:Connect(function()
			-- clicking selects this node in the Explorer; the SelectionChanged
			-- handler mirrors it back into the plugin highlight
			pcall(function() Selection:Set({ inst }) end)
		end)
	end

	btn.Parent = body
	addGuides(btn, item.guides)
	table.insert(bodyRows, { inst = item.inst, button = btn })
end

refreshView = function()
	clearBody()
	local g = activeGroup()
	if not g then return end
	pruneStale(g)
	local items = buildItems(g)
	for i, item in ipairs(items) do
		createRow(item, i)
	end
	computeSelectionFromStudio(g) -- highlight nodes selected in the Explorer
	applyHighlight()
	-- key panel
	if abbrevMode then
		keyLabel.Text = keyBlockText({ g })
	end
	applyLayout()
end

local function makeTab(parent, group, index, isActive)
	local b = createBtnVisual(parent, group.name)
	b.LayoutOrder = index * 10
	b.TextColor3 = THEME.header -- group tabs are blue
	local base = isActive and THEME.rowSel or THEME.btn
	b.BackgroundColor3 = base
	b.MouseEnter:Connect(function()
		if not isActive then b.BackgroundColor3 = THEME.btnHover end
	end)
	b.MouseLeave:Connect(function() b.BackgroundColor3 = base end)
	b.MouseButton1Click:Connect(function()
		activeIndex = index
		save()
		refreshAll() -- selection re-derives from the Explorer for the new group
	end)
	return b
end

local function makeArrow(parent, text, layoutOrder, cb)
	local b = createBtnVisual(parent, text)
	b.LayoutOrder = layoutOrder
	b.TextColor3 = THEME.text
	b.MouseEnter:Connect(function() b.BackgroundColor3 = THEME.btnHover end)
	b.MouseLeave:Connect(function() b.BackgroundColor3 = THEME.btn end)
	b.MouseButton1Click:Connect(function()
		local ok, err = pcall(cb)
		if not ok then warn("[ExplorerReference] " .. tostring(err)) end
	end)
	return b
end

refreshTabs = function()
	for _, child in ipairs(tabRow:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end
	for i, g in ipairs(groups) do
		local isActive = (i == activeIndex)
		if isActive and i > 1 then
			makeArrow(tabRow, "<", i * 10 - 1, function()
				groups[i], groups[i - 1] = groups[i - 1], groups[i]
				activeIndex = i - 1
				save()
				refreshAll()
			end)
		end
		makeTab(tabRow, g, i, isActive)
		if isActive and i < #groups then
			makeArrow(tabRow, ">", i * 10 + 1, function()
				groups[i], groups[i + 1] = groups[i + 1], groups[i]
				activeIndex = i + 1
				save()
				refreshAll()
			end)
		end
	end
	local addTab = makeButton(tabRow, "+ Group", function() newGroup() end)
	addTab.LayoutOrder = (#groups + 1) * 10
end

refreshNameBox = function()
	local g = activeGroup()
	nameBox.Text = g and g.name or ""
end

refreshAll = function()
	refreshTabs()
	refreshNameBox()
	refreshView()
end

--============================================================
-- Wiring: name box, del group, action buttons
--============================================================

nameBox.FocusLost:Connect(function()
	local g = activeGroup()
	if g and nameBox.Text ~= "" and nameBox.Text ~= g.name then
		g.name = nameBox.Text
		save()
		refreshTabs()
		refreshView() -- update the group header shown in the node list
	else
		refreshNameBox()
	end
end)

delGroupBtn.MouseButton1Click:Connect(function()
	if #groups <= 1 then
		-- clearing the last group = fresh slate
		groups[1] = { name = "Group 1", entries = {}, byInst = {}, counter = 0 }
		activeIndex = 1
	else
		table.remove(groups, activeIndex)
		if activeIndex > #groups then activeIndex = #groups end
	end
	save()
	refreshAll()
end)

-- Row 1: capture + copy
makeButton(actionRow, "+ Add Selection", function()
	local g = activeGroup()
	if not g then return end
	local sel = Selection:Get()
	if #sel == 0 then
		warn("[ExplorerReference] Select something in the Explorer first.")
		return
	end
	for _, inst in ipairs(sel) do addInstanceChain(g, inst) end
	save()
	refreshView() -- highlights the added nodes (their elements are still selected)
end, THEME.addBtn, THEME.addBtnHover)

do
	local _, paint = makeToggle(actionRow, "Multi-Select", function() return multiSelect end, function()
		multiSelect = not multiSelect
		if multiSelect then
			-- immediately capture whatever's already selected
			local g = activeGroup()
			if g then
				for _, inst in ipairs(Selection:Get()) do addInstanceChain(g, inst) end
				save()
				refreshView()
			end
		end
	end)
	paintMulti = paint
end

makeButton(actionRow, "Copy", function()
	local g = activeGroup()
	if not g then return end
	showCopy(groupToText(g))
end)

makeButton(actionRow, "Copy All", function()
	showCopy(allGroupsToText())
end)

-- Row 2: node operations. Single-target actions act on the latest selected node.
makeButton(actionRow2, "Sync", function()
	local g = activeGroup()
	if not g then return end
	pruneStale(g)
	save()
	refreshView()
end)

do
	local _, paint = makeToggle(actionRow2, "Overwrite", function()
		local g = activeGroup()
		local e = latestInst and g and entryFor(g, latestInst)
		return e ~= nil and e.detail ~= nil and e.detail ~= ""
	end, function()
		local g = activeGroup()
		if not g or not latestInst then
			warn("[ExplorerReference] Select a node (in the Explorer) first, then press Overwrite.")
			return
		end
		local e = entryFor(g, latestInst)
		if not e then return end
		owTarget = latestInst
		owBaseLabel.Text = defaultLabelFull(latestInst)
		owBox.Text = (e.detail and e.detail ~= "") and e.detail or ""
		owOverlay.Visible = true
		task.defer(function()
			owBox:CaptureFocus()
			owBox.CursorPosition = #owBox.Text + 1
		end)
	end)
	paintOverwrite = paint
end

makeButton(actionRow2, "Remove", function()
	local g = activeGroup()
	if not g or #selection == 0 then
		warn("[ExplorerReference] Select node(s) in the Explorer first.")
		return
	end
	local targets = {}
	for _, inst in ipairs(selection) do table.insert(targets, inst) end
	for _, inst in ipairs(targets) do
		if g.byInst[inst] then deleteSubtree(g, inst) end
	end
	save()
	refreshView()
end)

makeButton(actionRow2, "Up", function()
	local g = activeGroup()
	if not g or not latestInst then return end
	moveNode(g, latestInst, -1)
	save()
	refreshView()
end)

makeButton(actionRow2, "Down", function()
	local g = activeGroup()
	if not g or not latestInst then return end
	moveNode(g, latestInst, 1)
	save()
	refreshView()
end)

do
	local _, paint = makeToggle(actionRow2, "Pad", function()
		local g = activeGroup()
		local e = latestInst and g and entryFor(g, latestInst)
		return e ~= nil and e.padded == true
	end, function()
		local g = activeGroup()
		if not g or not latestInst then
			warn("[ExplorerReference] Select a node (in the Explorer) first, then press Pad.")
			return
		end
		local e = entryFor(g, latestInst)
		if not e then return end
		e.padded = not e.padded
		save()
		refreshView()
	end)
	paintPad = paint
end

do
	local _, paint = makeToggle(actionRow2, "Mark", function()
		local g = activeGroup()
		local e = latestInst and g and entryFor(g, latestInst)
		return e ~= nil and e.marked == true
	end, function()
		local g = activeGroup()
		if not g or not latestInst then
			warn("[ExplorerReference] Select a parent node (in the Explorer) first, then press Mark.")
			return
		end
		local e = entryFor(g, latestInst)
		if not e then return end
		e.marked = not e.marked
		save()
		refreshView()
	end)
	paintMark = paint
end

do
	local _, paint = makeToggle(actionRow2, "Abbrev", function() return abbrevMode end, function()
		abbrevMode = not abbrevMode
		save()
		refreshView()
	end)
	paintAbbrev = paint
end

-- Overwrite editor buttons
local function applyOverwrite()
	local g = activeGroup()
	local e = owTarget and g and entryFor(g, owTarget)
	if e then
		local txt = owBox.Text
		e.detail = (txt ~= "") and txt or nil
		save()
		refreshView()
	end
	owOverlay.Visible = false
	if paintOverwrite then paintOverwrite() end
end

owApply.MouseButton1Click:Connect(applyOverwrite)
owBox.FocusLost:Connect(function(enter)
	if enter then applyOverwrite() end
end)
owRemove.MouseButton1Click:Connect(function()
	local g = activeGroup()
	local e = owTarget and g and entryFor(g, owTarget)
	if e then
		e.detail = nil
		save()
		refreshView()
	end
	owOverlay.Visible = false
	if paintOverwrite then paintOverwrite() end
end)
owCancel.MouseButton1Click:Connect(function()
	owOverlay.Visible = false
end)

--============================================================
-- Toolbar + toggle + selection watcher
--============================================================

local toolbar = plugin:CreateToolbar("Explorer Reference")
local toggleButton = toolbar:CreateButton("ExplorerReferenceToggle", "Show / hide the Explorer Reference panel", "", "Explorer Ref")
toggleButton.ClickableWhenViewportHidden = true

toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
	if widget.Enabled then refreshAll() end
end)

Selection.SelectionChanged:Connect(function()
	if not widget.Enabled then return end
	local g = activeGroup()
	if not g then return end

	-- Multi-Select: auto-add whatever is selected in the Explorer, then rebuild
	-- (which re-derives the highlight, so newly added nodes show as selected).
	if multiSelect then
		local before = #g.entries
		for _, inst in ipairs(Selection:Get()) do addInstanceChain(g, inst) end
		if #g.entries ~= before then
			save()
			refreshView()
			return
		end
	end

	-- Otherwise just re-mirror the Explorer selection into the highlight.
	computeSelectionFromStudio(g)
	applyHighlight()
end)

--============================================================
-- Init
--============================================================

load()
if #groups == 0 then newGroup(true) end
applyLayout()
refreshAll()
