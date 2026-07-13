--[[
	Explorer Reference  —  v1 (prototype)
	------------------------------------------------------------------
	A Roblox Studio plugin for generating clean, copy-pasteable text
	references of your Explorer hierarchy (great for handing structure
	context to an AI).

	How it works
	------------
	  * Work is organized into GROUPS (the tabs across the top).
	  * Select instance(s) in the Explorer, hit "Add Selection", and the
	    plugin whitelists them PLUS their whole ancestor chain up to the
	    service, then draws the tree with correct indentation.
	  * The tree is rebuilt from LIVE parent data every refresh, so if you
	    move / rename / reparent something in Studio and hit "Sync", the
	    indentation fixes itself automatically. No more hand-editing markers.
	  * Click a node to select it (also selects it in Studio). Then you can
	    Delete it, or Move it Up / Down among its siblings.
	  * "Copy" / "Copy All" open a select-all textbox you Ctrl+C from
	    (Studio plugins can't write the clipboard directly).

	Output format (v1): 2-space indentation, `Name (ClassName)` per line,
	`---- GroupName ----` section headers. Compact + maximally AI-legible.
	Change INDENT / header style below to taste.

	This is a styling/feel prototype — the goal is to react to the look and
	the core loop before we build the heavier features.
--]]

if not plugin then
	return
end

local Selection = game:GetService("Selection")
local HttpService = game:GetService("HttpService")

--============================================================
-- Config / Theme
--============================================================

local INDENT = "  " -- 2 spaces per depth level
local SETTING_KEY = "ExplorerReference_Data_v1"

local THEME = {
	bg       = Color3.fromRGB(30, 30, 30),
	bar      = Color3.fromRGB(37, 37, 38),
	btn      = Color3.fromRGB(51, 51, 54),
	btnHover = Color3.fromRGB(66, 66, 70),
	text     = Color3.fromRGB(220, 220, 220),
	textDim  = Color3.fromRGB(140, 140, 140),
	header   = Color3.fromRGB(96, 160, 255),
	service  = Color3.fromRGB(120, 200, 140),
	rowSel   = Color3.fromRGB(38, 79, 120),
	rowHover = Color3.fromRGB(45, 45, 48),
	border   = Color3.fromRGB(60, 60, 62),
}

--============================================================
-- State
--============================================================

-- A group: { name, entries = { {inst, order}... }, byInst = {[Instance]=entry}, counter }
local groups = {}
local activeIndex = 1
local selectedInst = nil -- node currently highlighted inside the plugin

-- forward declarations (assigned later)
local refreshAll, refreshView, refreshTabs, refreshStatus, save

--============================================================
-- Safe accessors (instances may be destroyed / detached)
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
-- Model
--============================================================

local function activeGroup()
	return groups[activeIndex]
end

-- Add an instance and its whole ancestor chain (service -> ... -> inst)
local function addInstanceChain(group, inst)
	if not isValid(inst) then return end
	if inst == game then return end

	local chain = {}
	local n = inst
	while n and n ~= game do
		table.insert(chain, 1, n)
		if safeParent(n) == game then break end
		n = safeParent(n)
	end

	for _, node in ipairs(chain) do
		if not group.byInst[node] then
			local e = { inst = node, order = group.counter }
			group.counter += 1
			table.insert(group.entries, e)
			group.byInst[node] = e
		end
	end
end

-- Remove stale (destroyed / detached) entries
local function pruneStale(group)
	local kept = {}
	local removed = false
	for _, e in ipairs(group.entries) do
		if isValid(e.inst) then
			table.insert(kept, e)
		else
			group.byInst[e.inst] = nil
			removed = true
		end
	end
	group.entries = kept
	return removed
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

-- Build a flat list of display items for a group.
-- Each item: { kind = "header"|"blank"|"service"|"node", text, inst?, depth?, detached? }
local function buildItems(group)
	local items = {}
	table.insert(items, { kind = "header", text = group.name })

	local function dfs(entry, depth)
		local inst = entry.inst
		local svc = isService(inst)
		local label
		if svc then
			label = safeName(inst)
		else
			label = safeName(inst) .. " (" .. safeClass(inst) .. ")"
		end
		table.insert(items, {
			kind = svc and "service" or "node",
			text = string.rep(INDENT, depth) .. label,
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
		table.insert(items, { kind = "node", text = "  (empty — select something in the Explorer and press Add Selection)", inst = nil, depth = 0, detached = true })
		return items
	end

	for i, root in ipairs(roots) do
		if i > 1 then
			table.insert(items, { kind = "blank" })
		end
		dfs(root, 0)
	end
	return items
end

-- Produce the copy-pasteable text for one group
local function groupToText(group)
	local items = buildItems(group)
	local lines = {}
	for _, it in ipairs(items) do
		if it.kind == "header" then
			table.insert(lines, "---- " .. it.text .. " " .. string.rep("-", math.max(4, 44 - #it.text)))
		elseif it.kind == "blank" then
			table.insert(lines, "")
		elseif it.inst then
			table.insert(lines, it.text)
		end
	end
	return table.concat(lines, "\n")
end

local function allGroupsToText()
	local blocks = {}
	for _, g in ipairs(groups) do
		table.insert(blocks, groupToText(g))
	end
	return table.concat(blocks, "\n\n\n")
end

-- Delete a node and everything under it (within this group)
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

-- Move a node up/down among its display siblings
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
-- Persistence (best-effort: store name-paths, re-resolve on load)
--============================================================

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
	local data = { active = activeIndex, groups = {} }
	for _, g in ipairs(groups) do
		local gg = { name = g.name, nodes = {} }
		for _, e in ipairs(g.entries) do
			local path = pathOf(e.inst)
			if path then
				table.insert(gg.nodes, { path = path, order = e.order })
			end
		end
		table.insert(data.groups, gg)
	end
	pcall(function()
		plugin:SetSetting(SETTING_KEY, HttpService:JSONEncode(data))
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
	local raw = plugin:GetSetting(SETTING_KEY)
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
				local e = { inst = inst, order = nd.order or g.counter }
				table.insert(g.entries, e)
				g.byInst[inst] = e
				g.counter = math.max(g.counter, (nd.order or 0) + 1)
			end
		end
		table.insert(groups, g)
	end
	activeIndex = data.active or 1
	if activeIndex < 1 or activeIndex > #groups then
		activeIndex = 1
	end
end

--============================================================
-- UI construction
--============================================================

local toolbar = plugin:CreateToolbar("Explorer Reference")
local toggleButton = toolbar:CreateButton("ExplorerReferenceToggle", "Show / hide the Explorer Reference panel", "", "Explorer Ref")
toggleButton.ClickableWhenViewportHidden = true

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float,
	false, -- start closed
	false,
	440, 560, -- default size
	320, 320 -- min size
)
local widget = plugin:CreateDockWidgetPluginGui("ExplorerReferencePanel", widgetInfo)
widget.Title = "Explorer Reference"

local root = Instance.new("Frame")
root.Size = UDim2.new(1, 0, 1, 0)
root.BackgroundColor3 = THEME.bg
root.BorderSizePixel = 0
root.Parent = widget

--------------------------------------------------------------
-- Helpers for building widgets
--------------------------------------------------------------

local function makeButton(parent, text, tooltip, cb)
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
	b.AutomaticSize = Enum.AutomaticSize.X

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = b
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = b

	b.MouseEnter:Connect(function() b.BackgroundColor3 = THEME.btnHover end)
	b.MouseLeave:Connect(function() b.BackgroundColor3 = THEME.btn end)
	b.MouseButton1Click:Connect(function()
		local ok, err = pcall(cb)
		if not ok then warn("[ExplorerReference] " .. tostring(err)) end
	end)
	b.Parent = parent
	return b
end

-- A horizontal scrolling strip that holds a row of buttons/tabs
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

--------------------------------------------------------------
-- Top bars
--------------------------------------------------------------

local actionRow = makeStrip(root, 4, 30)
local tabRow = makeStrip(root, 38, 30)

-- Status label
local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundColor3 = THEME.bar
statusLabel.BorderSizePixel = 0
statusLabel.Size = UDim2.new(1, 0, 0, 20)
statusLabel.Position = UDim2.new(0, 0, 0, 70)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextColor3 = THEME.textDim
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Text = ""
statusLabel.Parent = root
local statusPad = Instance.new("UIPadding")
statusPad.PaddingLeft = UDim.new(0, 8)
statusPad.Parent = statusLabel

--------------------------------------------------------------
-- Body (node list)
--------------------------------------------------------------

local body = Instance.new("ScrollingFrame")
body.BackgroundColor3 = THEME.bg
body.BorderSizePixel = 0
body.Position = UDim2.new(0, 0, 0, 92)
body.Size = UDim2.new(1, 0, 1, -92)
body.ScrollBarThickness = 6
body.ScrollingDirection = Enum.ScrollingDirection.XY
body.AutomaticCanvasSize = Enum.AutomaticSize.XY
body.CanvasSize = UDim2.new(0, 0, 0, 0)
body.Parent = root

local bodyLayout = Instance.new("UIListLayout")
bodyLayout.FillDirection = Enum.FillDirection.Vertical
bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
bodyLayout.Parent = body

local bodyPad = Instance.new("UIPadding")
bodyPad.PaddingTop = UDim.new(0, 6)
bodyPad.PaddingLeft = UDim.new(0, 6)
bodyPad.PaddingBottom = UDim.new(0, 12)
bodyPad.Parent = body

local bodyRows = {} -- { {inst, button} ... }

--------------------------------------------------------------
-- Copy overlay
--------------------------------------------------------------

local overlay = Instance.new("Frame")
overlay.BackgroundColor3 = THEME.bg
overlay.BorderSizePixel = 0
overlay.Size = UDim2.new(1, 0, 1, 0)
overlay.Visible = false
overlay.ZIndex = 10
overlay.Parent = root

local overlayInfo = Instance.new("TextLabel")
overlayInfo.BackgroundColor3 = THEME.bar
overlayInfo.BorderSizePixel = 0
overlayInfo.Size = UDim2.new(1, 0, 0, 26)
overlayInfo.Font = Enum.Font.Gotham
overlayInfo.TextSize = 12
overlayInfo.TextColor3 = THEME.text
overlayInfo.Text = "  Press Ctrl+C to copy, then close."
overlayInfo.TextXAlignment = Enum.TextXAlignment.Left
overlayInfo.ZIndex = 11
overlayInfo.Parent = overlay

local overlayClose = makeButton(overlay, "Close", "Close copy view", function()
	overlay.Visible = false
end)
overlayClose.AnchorPoint = Vector2.new(1, 0)
overlayClose.Position = UDim2.new(1, -6, 0, 2)
overlayClose.Size = UDim2.new(0, 0, 0, 22)
overlayClose.ZIndex = 11

local copyBox = Instance.new("TextBox")
copyBox.BackgroundColor3 = THEME.bg
copyBox.BorderColor3 = THEME.border
copyBox.BorderSizePixel = 1
copyBox.Position = UDim2.new(0, 0, 0, 26)
copyBox.Size = UDim2.new(1, 0, 1, -26)
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
copyBox.ZIndex = 11
copyBox.Parent = overlay
local copyPad = Instance.new("UIPadding")
copyPad.PaddingLeft = UDim.new(0, 6)
copyPad.PaddingTop = UDim.new(0, 4)
copyPad.Parent = copyBox

local function showCopy(text)
	copyBox.Text = text
	overlay.Visible = true
	task.defer(function()
		copyBox:CaptureFocus()
		copyBox.CursorPosition = #copyBox.Text + 1
		copyBox.SelectionStart = 1
	end)
end

--============================================================
-- Refresh functions
--============================================================

local function setSelected(inst)
	selectedInst = inst
	for _, row in ipairs(bodyRows) do
		if row.inst and row.inst == inst then
			row.button.BackgroundTransparency = 0
			row.button.BackgroundColor3 = THEME.rowSel
		else
			row.button.BackgroundTransparency = 1
		end
	end
end

refreshStatus = function()
	local g = activeGroup()
	local nodeCount = g and #g.entries or 0
	local selCount = 0
	pcall(function() selCount = #Selection:Get() end)
	local name = g and g.name or "—"
	statusLabel.Text = string.format("Group '%s'  •  %d nodes  •  %d selected in Studio", name, nodeCount, selCount)
end

local function clearBody()
	bodyRows = {}
	for _, child in ipairs(body:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function createRow(item, order)
	if item.kind == "blank" then
		local spacer = Instance.new("Frame")
		spacer.BackgroundTransparency = 1
		spacer.Size = UDim2.new(1, 0, 0, 8)
		spacer.LayoutOrder = order
		spacer.Parent = body
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

	-- service / node row
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
	btn.Text = item.text
	btn.LayoutOrder = order
	if item.kind == "service" then
		btn.TextColor3 = THEME.service
	elseif item.detached then
		btn.TextColor3 = THEME.textDim
	else
		btn.TextColor3 = THEME.text
	end

	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = btn

	if item.inst then
		btn.MouseEnter:Connect(function()
			if selectedInst ~= item.inst then
				btn.BackgroundTransparency = 0
				btn.BackgroundColor3 = THEME.rowHover
			end
		end)
		btn.MouseLeave:Connect(function()
			if selectedInst ~= item.inst then
				btn.BackgroundTransparency = 1
			end
		end)
		btn.MouseButton1Click:Connect(function()
			setSelected(item.inst)
			pcall(function() Selection:Set({ item.inst }) end)
			refreshStatus()
		end)
	end

	btn.Parent = body
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
	-- reapply highlight if the selected node still exists
	if selectedInst then
		setSelected(selectedInst)
	end
	refreshStatus()
end

refreshTabs = function()
	for _, child in ipairs(tabRow:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	for i, g in ipairs(groups) do
		local isActive = (i == activeIndex)
		local tab = makeButton(tabRow, g.name, "Switch to " .. g.name, function()
			activeIndex = i
			selectedInst = nil
			save()
			refreshAll()
		end)
		tab.LayoutOrder = i
		if isActive then
			tab.BackgroundColor3 = THEME.rowSel
			tab.MouseLeave:Connect(function() tab.BackgroundColor3 = THEME.rowSel end)
		end
	end

	local addTab = makeButton(tabRow, "+ Group", "Create a new group", function()
		newGroup()
	end)
	addTab.LayoutOrder = #groups + 1
end

refreshAll = function()
	refreshTabs()
	refreshView()
	refreshStatus()
end

--============================================================
-- Action buttons
--============================================================

makeButton(actionRow, "+ Add Selection", "Add the current Explorer selection (and its ancestors) to this group", function()
	local g = activeGroup()
	if not g then return end
	local sel = Selection:Get()
	if #sel == 0 then
		statusLabel.Text = "Select something in the Explorer first."
		return
	end
	for _, inst in ipairs(sel) do
		addInstanceChain(g, inst)
	end
	save()
	refreshView()
end)

makeButton(actionRow, "Sync", "Re-read live hierarchy and prune deleted nodes", function()
	local g = activeGroup()
	if not g then return end
	pruneStale(g)
	save()
	refreshView()
end)

makeButton(actionRow, "Delete", "Remove the selected node (and its children) from this group", function()
	local g = activeGroup()
	if not g or not selectedInst then
		statusLabel.Text = "Click a node in the list first."
		return
	end
	deleteSubtree(g, selectedInst)
	selectedInst = nil
	save()
	refreshView()
end)

makeButton(actionRow, "Up", "Move selected node up among its siblings", function()
	local g = activeGroup()
	if not g or not selectedInst then return end
	moveNode(g, selectedInst, -1)
	save()
	refreshView()
end)

makeButton(actionRow, "Down", "Move selected node down among its siblings", function()
	local g = activeGroup()
	if not g or not selectedInst then return end
	moveNode(g, selectedInst, 1)
	save()
	refreshView()
end)

makeButton(actionRow, "Copy", "Copy this group's text", function()
	local g = activeGroup()
	if not g then return end
	showCopy(groupToText(g))
end)

makeButton(actionRow, "Copy All", "Copy every group's text", function()
	showCopy(allGroupsToText())
end)

--============================================================
-- Group management buttons (on the tab row area via extra controls)
--============================================================

-- Rename field lives on the status bar area for discoverability
local renameBox = Instance.new("TextBox")
renameBox.BackgroundColor3 = THEME.btn
renameBox.BorderSizePixel = 0
renameBox.AnchorPoint = Vector2.new(1, 0)
renameBox.Position = UDim2.new(1, -74, 0, 71)
renameBox.Size = UDim2.new(0, 130, 0, 18)
renameBox.Font = Enum.Font.Gotham
renameBox.TextSize = 12
renameBox.TextColor3 = THEME.text
renameBox.PlaceholderText = "rename group…"
renameBox.Text = ""
renameBox.ClearTextOnFocus = false
renameBox.Parent = root
local rnCorner = Instance.new("UICorner")
rnCorner.CornerRadius = UDim.new(0, 4)
rnCorner.Parent = renameBox
local rnPad = Instance.new("UIPadding")
rnPad.PaddingLeft = UDim.new(0, 6)
rnPad.Parent = renameBox

renameBox.FocusLost:Connect(function(enter)
	local g = activeGroup()
	if g and renameBox.Text ~= "" then
		g.name = renameBox.Text
		save()
		refreshAll()
	end
	renameBox.Text = ""
end)

local delGroupBtn = Instance.new("TextButton")
delGroupBtn.AutoButtonColor = false
delGroupBtn.BackgroundColor3 = THEME.btn
delGroupBtn.BorderSizePixel = 0
delGroupBtn.AnchorPoint = Vector2.new(1, 0)
delGroupBtn.Position = UDim2.new(1, -6, 0, 71)
delGroupBtn.Size = UDim2.new(0, 62, 0, 18)
delGroupBtn.Font = Enum.Font.Gotham
delGroupBtn.TextSize = 12
delGroupBtn.TextColor3 = THEME.text
delGroupBtn.Text = "Del Group"
delGroupBtn.Parent = root
local dgCorner = Instance.new("UICorner")
dgCorner.CornerRadius = UDim.new(0, 4)
dgCorner.Parent = delGroupBtn
delGroupBtn.MouseEnter:Connect(function() delGroupBtn.BackgroundColor3 = THEME.btnHover end)
delGroupBtn.MouseLeave:Connect(function() delGroupBtn.BackgroundColor3 = THEME.btn end)
delGroupBtn.MouseButton1Click:Connect(function()
	if #groups <= 1 then
		statusLabel.Text = "Can't delete the last group."
		return
	end
	table.remove(groups, activeIndex)
	if activeIndex > #groups then activeIndex = #groups end
	selectedInst = nil
	save()
	refreshAll()
end)

--============================================================
-- Wiring
--============================================================

toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
	if widget.Enabled then
		refreshAll()
	end
end)

Selection.SelectionChanged:Connect(function()
	if widget.Enabled then
		refreshStatus()
	end
end)

--============================================================
-- Init
--============================================================

load()
if #groups == 0 then
	newGroup(true)
end
refreshAll()
