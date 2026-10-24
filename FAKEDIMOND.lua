--[[ ============================================================================
  CHILLI VKING — KEY GATE
  ----------------------------------------------------------------------------
  Dùng: dán file này vào executor, hoặc nạp nó TRƯỚC hub:

      loadstring(game:HttpGet("<link chilli_key.lua>"))()

  Nếu bạn muốn gate cho hub có sẵn trong máy (file .lua), dùng:

      local ok = loadstring(game:HttpGet("<link chilli_key.lua>"))()
      if ok then loadstring(readfile("chillihub.lua"))() end

  Key sống 16 GIỜ, khoá theo HWID (ClientId). Key lưu ở:
      chilli_key.txt      (nội dung key)
      chilli_key_meta.json (hwid + thời điểm hết hạn, để hiện đếm ngược)

  Không có key hợp lệ -> trả về false, KHÔNG chạy hub.
  ----------------------------------------------------------------------------
  CHO NHÀ PHÁT TRIỂN
  - Mọi thứ hay cần sửa nằm trong bảng CFG bên dưới.
  - CFG.DEBUG = true -> bỏ qua bước kiểm tra key (CHỈ để test ở nhà).
    Nhớ đổi lại false trước khi phát hành.
============================================================================ ]]

local CFG = {
	-- Link Worker của bạn (không có dấu / ở cuối)
	API = "https://chillihubvking-claimkey.dongbackhai600.workers.dev",

	-- Trang web lấy key (mở bằng nút "Lấy Key")
	WEB = "https://chillihubvking-claimkey.dongbackhai600.workers.dev/",

	-- Thời gian sống của key, chỉ để hiển thị/đếm ngược (server mới là nơi quyết định)
	TTL_HOURS = 16,

	-- File lưu trên máy
	KEY_FILE = "chilli_key.txt",
	META_FILE = "chilli_key_meta.json",

	-- Kiểm tra lại key với server mỗi bao nhiêu giây khi hub đang chạy
	RECHECK_EVERY = 600,

	-- Bỏ qua gate (test ở nhà). PHẢI là false khi phát hành.
	DEBUG = false,
}

-- ============================================================================
-- Tiện ích
-- ============================================================================

local HS = game:GetService("HttpService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LP = Players.LocalPlayer

local function hasFileApi()
	return type(isfile) == "function"
		and type(readfile) == "function"
		and type(writefile) == "function"
end

local function readText(path)
	if not hasFileApi() or not isfile(path) then
		return nil
	end
	local ok, data = pcall(readfile, path)
	if ok and type(data) == "string" then
		return data
	end
	return nil
end

local function writeText(path, text)
	if not hasFileApi() then
		return false
	end
	return (pcall(writefile, path, text))
end

local function delfileSafe(path)
	if type(delfile) == "function" and hasFileApi() and isfile(path) then
		pcall(delfile, path)
	end
end

-- HWID: ClientId là thứ ổn định nhất trên Roblox; fallback sang UserId.
local HWID = LP:GetAttribute("ClientId")
if type(HWID) ~= "string" or #HWID < 6 then
	pcall(function()
		local analytics = game:GetService("RbxAnalyticsService")
		local id = analytics and analytics:GetClientId()
		if type(id) == "string" and #id >= 6 then
			HWID = id
		end
	end)
end
if type(HWID) ~= "string" or #HWID < 6 then
	HWID = "user-" .. tostring(LP.UserId)
end

local function httpJson(method, url, payload)
	if type(request) ~= "function" then
		return nil, "Executor không có hàm request()"
	end
	local opts = {
		Url = url,
		Method = method,
		Headers = { ["Content-Type"] = "application/json" },
	}
	if payload then
		opts.Body = HS:JSONEncode(payload)
	end
	local ok, res = pcall(request, opts)
	if not ok or type(res) ~= "table" then
		return nil, "Không gọi được server: " .. tostring(res)
	end
	local body = res.Body or res.body
	if type(body) ~= "string" or body == "" then
		return nil, "Server trả về rỗng (mã " .. tostring(res.StatusCode or res.Status) .. ")"
	end
	local okDecode, data = pcall(HS.JSONDecode, HS, body)
	if not okDecode or type(data) ~= "table" then
		return nil, "Phản hồi không phải JSON hợp lệ"
	end
	return data, nil
end

-- "16h 05m 12s"
local function formatRemaining(ms)
	if type(ms) ~= "number" or ms < 0 then
		ms = 0
	end
	local total = math.floor(ms / 1000)
	local h = math.floor(total / 3600)
	local m = math.floor((total % 3600) / 60)
	local s = total % 60
	return string.format("%dh %02dm %02ds", h, m, s)
end

-- Chuẩn hoá key người dùng gõ: "chil abcd efgh ijkl" -> "CHIL-ABCD-EFGH-IJKL"
-- Vẫn nhận prefix FUJI cũ để key đã phát hành trước đó không bị vô hiệu.
local function normalizeKey(raw)
	local s = string.upper(tostring(raw or "")):gsub("[^A-Z0-9]", "")
	if #s ~= 16 then
		return nil
	end
	local prefix = string.sub(s, 1, 4)
	if prefix ~= "CHIL" and prefix ~= "FUJI" then
		return nil
	end
	return prefix .. "-" .. s:sub(5, 8) .. "-" .. s:sub(9, 12) .. "-" .. s:sub(13, 16)
end

-- ============================================================================
-- Trạng thái lưu máy
-- ============================================================================

local function loadMeta()
	local raw = readText(CFG.META_FILE)
	if not raw then
		return {}
	end
	local ok, data = pcall(HS.JSONDecode, HS, raw)
	if ok and type(data) == "table" then
		return data
	end
	return {}
end

local function saveMeta(meta)
	writeText(CFG.META_FILE, HS:JSONEncode(meta))
end

local function loadKey()
	local raw = readText(CFG.KEY_FILE)
	if type(raw) ~= "string" then
		return nil
	end
	return normalizeKey(raw)
end

local function saveKey(key, expiresAt)
	writeText(CFG.KEY_FILE, key .. "\n")
	local meta = loadMeta()
	meta.hwid = HWID
	meta.key = key
	meta.expiresAt = expiresAt
	meta.savedAt = os.time()
	saveMeta(meta)
end

local function clearKey()
	delfileSafe(CFG.KEY_FILE)
	delfileSafe(CFG.META_FILE)
end

-- ============================================================================
-- Gọi server
-- ============================================================================

local function apiVerify(key)
	return httpJson("POST", CFG.API .. "/api/verify", { key = key, hwid = HWID })
end

local function apiClaim()
	return httpJson("POST", CFG.API .. "/api/claim", { hwid = HWID })
end

-- ============================================================================
-- UI
-- ============================================================================

local THEME = {
	bg = Color3.fromRGB(8, 4, 18),
	card = Color3.fromRGB(18, 12, 38),
	line = Color3.fromRGB(76, 49, 132),
	text = Color3.fromRGB(245, 243, 255),
	dim = Color3.fromRGB(172, 160, 205),
	accent = Color3.fromRGB(139, 92, 246),
	accent2 = Color3.fromRGB(34, 211, 238),
	good = Color3.fromRGB(95, 214, 138),
	bad = Color3.fromRGB(255, 110, 130),
	font = Enum.Font.GothamMedium,
	fontBold = Enum.Font.GothamBold,
	mono = Enum.Font.Code,
}

local function corner(obj, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 10)
	c.Parent = obj
	return c
end

local function stroke(obj, color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = color or THEME.line
	s.Thickness = thickness or 1
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = obj
	return s
end

local function makeGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "ChilliVKingKeyGate"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 9999
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local ok = pcall(function()
		gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
	end)
	if not ok or not gui.Parent then
		gui.Parent = LP:WaitForChild("PlayerGui")
	end
	return gui
end

-- Trả về: key (string|nil), thông điệp lỗi cuối (string|nil)
local function openUI(prefillKey, prefilledResult)
	local gui = makeGui()

	local frame = Instance.new("Frame")
	frame.Name = "Main"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(420, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = THEME.card
	frame.BorderSizePixel = 0
	frame.Parent = gui
	corner(frame, 16)
	stroke(frame, THEME.line, 1)
	local frameStroke = frame:FindFirstChildOfClass("UIStroke")

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 22)
	pad.PaddingRight = UDim.new(0, 22)
	pad.PaddingTop = UDim.new(0, 22)
	pad.PaddingBottom = UDim.new(0, 22)
	pad.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	local function label(props)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Font = THEME.font
		l.TextColor3 = THEME.text
		l.TextSize = 13
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Text = ""
		l.Size = UDim2.new(1, 0, 0, 0)
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.TextWrapped = true
		for k, v in pairs(props) do
			l[k] = v
		end
		l.Parent = frame
		return l
	end

	local function button(text, primary)
		local b = Instance.new("TextButton")
		b.AutoButtonColor = false
		b.Font = THEME.fontBold
		b.TextSize = 14
		b.Text = text
		b.TextColor3 = Color3.new(1, 1, 1)
		b.BackgroundColor3 = primary and THEME.accent or THEME.card
		b.BorderSizePixel = 0
		b.Size = primary and UDim2.new(1, 0, 0, 40) or UDim2.new(0, 0, 0, 34)
		b.AutomaticSize = primary and Enum.AutomaticSize.None or Enum.AutomaticSize.X
		if not primary then
			b.PaddingLeft = 0
		end
		b.Parent = frame
		corner(b, primary and 12 or 9)
		if primary then
			stroke(b, THEME.line, 1, 1)
			local grad = Instance.new("UIGradient")
			grad.Color = ColorSequence.new(THEME.accent, THEME.accent2)
			grad.Parent = b
		end
		b.MouseEnter:Connect(function()
			TweenService:Create(b, TweenInfo.new(0.12), { BackgroundTransparency = primary and 0 or 0.35 }):Play()
		end)
		b.MouseLeave:Connect(function()
			TweenService:Create(b, TweenInfo.new(0.12), { BackgroundTransparency = primary and 0 or 0.65 }):Play()
		end)
		return b
	end

	-- Tiêu đề
	local titleRow = Instance.new("Frame")
	titleRow.BackgroundTransparency = 1
	titleRow.Size = UDim2.new(1, 0, 0, 44)
	titleRow.LayoutOrder = 1
	titleRow.Parent = frame

	local logo = Instance.new("Frame")
	logo.Size = UDim2.fromOffset(44, 44)
	logo.BackgroundColor3 = THEME.accent
	logo.BorderSizePixel = 0
	logo.Parent = titleRow
	corner(logo, 12)
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(THEME.accent, THEME.accent2)
	grad.Rotation = 35
	grad.Parent = logo
	local logoTxt = Instance.new("TextLabel")
	logoTxt.BackgroundTransparency = 1
	logoTxt.Size = UDim2.fromScale(1, 1)
	logoTxt.Font = THEME.fontBold
	logoTxt.TextSize = 13
	logoTxt.TextColor3 = Color3.new(1, 1, 1)
	logoTxt.Text = "CV"
	logoTxt.Parent = logo

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(56, 2)
	title.Size = UDim2.new(1, -56, 0, 22)
	title.Font = THEME.fontBold
	title.TextSize = 19
	title.TextColor3 = THEME.text
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Chilli VKing — Key"
	title.Parent = titleRow

	local subtitle = Instance.new("TextLabel")
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromOffset(56, 24)
	subtitle.Size = UDim2.new(1, -56, 0, 18)
	subtitle.Font = THEME.font
	subtitle.TextSize = 12
	subtitle.TextColor3 = THEME.dim
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.Text = "Key sống 16 giờ · khoá theo HWID"
	subtitle.Parent = titleRow

	-- HWID
	local hwidLabel = label({
		Text = "HWID CỦA BẠN",
		Font = THEME.fontBold,
		TextSize = 11,
		TextColor3 = THEME.dim,
		LayoutOrder = 2,
	})

	local hwidBox = Instance.new("Frame")
	hwidBox.Size = UDim2.new(1, 0, 0, 36)
	hwidBox.BackgroundColor3 = THEME.bg
	hwidBox.BorderSizePixel = 0
	hwidBox.LayoutOrder = 3
	hwidBox.Parent = frame
	corner(hwidBox, 9)
	stroke(hwidBox, THEME.line, 1, 0.4)

	local hwidText = Instance.new("TextLabel")
	hwidText.BackgroundTransparency = 1
	hwidText.Position = UDim2.fromOffset(12, 0)
	hwidText.Size = UDim2.new(1, -80, 1, 0)
	hwidText.Font = THEME.mono
	hwidText.TextSize = 13
	hwidText.TextColor3 = THEME.text
	hwidText.TextTruncate = Enum.TextTruncate.AtEnd
	hwidText.TextXAlignment = Enum.TextXAlignment.Left
	hwidText.Text = HWID
	hwidText.Parent = hwidBox

	local copyHwid = Instance.new("TextButton")
	copyHwid.AnchorPoint = Vector2.new(1, 0.5)
	copyHwid.Position = UDim2.new(1, -6, 0.5, 0)
	copyHwid.Size = UDim2.fromOffset(64, 24)
	copyHwid.BackgroundColor3 = THEME.card
	copyHwid.BackgroundTransparency = 0.35
	copyHwid.BorderSizePixel = 0
	copyHwid.Font = THEME.fontBold
	copyHwid.TextSize = 12
	copyHwid.TextColor3 = THEME.text
	copyHwid.Text = "Copy"
	copyHwid.AutoButtonColor = false
	copyHwid.Parent = hwidBox
	corner(copyHwid, 7)

	-- Key input
	label({
		Text = "KEY",
		Font = THEME.fontBold,
		TextSize = 11,
		TextColor3 = THEME.dim,
		LayoutOrder = 4,
	})

	local inputBox = Instance.new("Frame")
	inputBox.Size = UDim2.new(1, 0, 0, 38)
	inputBox.BackgroundColor3 = THEME.bg
	inputBox.BorderSizePixel = 0
	inputBox.LayoutOrder = 5
	inputBox.Parent = frame
	corner(inputBox, 9)
	local inputStroke = stroke(inputBox, THEME.line, 1, 0.4)

	local input = Instance.new("TextBox")
	input.BackgroundTransparency = 1
	input.Position = UDim2.fromOffset(12, 0)
	input.Size = UDim2.new(1, -24, 1, 0)
	input.Font = THEME.mono
	input.TextSize = 14
	input.TextColor3 = THEME.text
	input.PlaceholderText = "CHIL-XXXX-XXXX-XXXX"
	input.PlaceholderColor3 = THEME.dim
	input.TextXAlignment = Enum.TextXAlignment.Left
	input.ClearTextOnFocus = false
	input.Text = prefillKey or ""
	input.Parent = inputBox

	-- Dòng thông điệp
	local message = label({
		Text = "",
		TextSize = 12,
		TextColor3 = THEME.dim,
		LayoutOrder = 6,
		Visible = false,
	})

	local function say(text, kind)
		if not text or text == "" then
			message.Visible = false
			message.Text = ""
			return
		end
		message.Visible = true
		message.Text = text
		if kind == "good" then
			message.TextColor3 = THEME.good
		elseif kind == "bad" then
			message.TextColor3 = THEME.bad
		else
			message.TextColor3 = THEME.dim
		end
	end

	if prefilledResult then
		say(prefilledResult, "dim")
	end

	-- Nút
	local applyBtn = button("Xác nhận Key", true)
	applyBtn.LayoutOrder = 7

	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 34)
	row.LayoutOrder = 8
	row.Parent = frame

	local uiList = Instance.new("UIListLayout")
	uiList.FillDirection = Enum.FillDirection.Horizontal
	uiList.Padding = UDim.new(0, 8)
	uiList.SortOrder = Enum.SortOrder.LayoutOrder
	uiList.Parent = row

	local function smallButton(parent, text, order)
		local b = Instance.new("TextButton")
		b.AutoButtonColor = false
		b.Font = THEME.fontBold
		b.TextSize = 12
		b.Text = text
		b.TextColor3 = THEME.text
		b.BackgroundColor3 = THEME.card
		b.BackgroundTransparency = 0.35
		b.BorderSizePixel = 0
		b.Size = UDim2.fromOffset(0, 34)
		b.AutomaticSize = Enum.AutomaticSize.X
		b.LayoutOrder = order
		b.Parent = parent
		corner(b, 9)
		local txtPad = Instance.new("UIPadding")
		txtPad.PaddingLeft = UDim.new(0, 14)
		txtPad.PaddingRight = UDim.new(0, 14)
		txtPad.Parent = b
		b.MouseEnter:Connect(function()
			TweenService:Create(b, TweenInfo.new(0.12), { BackgroundTransparency = 0 }):Play()
		end)
		b.MouseLeave:Connect(function()
			TweenService:Create(b, TweenInfo.new(0.12), { BackgroundTransparency = 0.35 }):Play()
		end)
		return b
	end

	local getKeyBtn = smallButton(row, "Lấy Key", 1)
	local pasteBtn = smallButton(row, "Dán Key", 2)
	local checkBtn = smallButton(row, "Kiểm tra", 3)

	local footer = label({
		Text = "",
		TextSize = 11,
		TextColor3 = THEME.dim,
		LayoutOrder = 9,
	})

	-- Kéo thả
	local dragging, dragStart, startPos
	frame.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = i.Position
			startPos = frame.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if not dragging then
			return
		end
		if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
			local delta = i.Position - dragStart
			frame.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end
	end)
	UserInputService.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	input.Focused:Connect(function()
		TweenService:Create(inputStroke, TweenInfo.new(0.15), { Color = THEME.accent, Transparency = 0 }):Play()
	end)
	input.FocusLost:Connect(function()
		TweenService:Create(inputStroke, TweenInfo.new(0.15), { Color = THEME.line, Transparency = 0.4 }):Play()
	end)

	local finished = false
	local resultKey = nil

	local function close(key)
		if finished then
			return
		end
		finished = true
		resultKey = key
		pcall(function()
			gui:Destroy()
		end)
	end

	local function copyToClipboard(text)
		local ok = pcall(function()
			if type(setclipboard) == "function" then
				setclipboard(text)
				return true
			end
			return false
		end)
		return ok
	end

	copyHwid.MouseButton1Click:Connect(function()
		if copyToClipboard(HWID) then
			copyHwid.Text = "Đã copy"
			say("Đã copy HWID — dán vào trang web để lấy key.", "good")
			task.delay(1.6, function()
				if copyHwid.Parent then
					copyHwid.Text = "Copy"
				end
			end)
		else
			say("Executor không hỗ trợ setclipboard. Copy tay nhé.", "bad")
		end
	end)

	getKeyBtn.MouseButton1Click:Connect(function()
		if type(setclipboard) == "function" then
			pcall(setclipboard, HWID)
		end
		local opened = pcall(function()
			if type(setclipboard) == "function" then
				setclipboard(HWID)
			end
		end)
		say("Đang mở trang lấy key… HWID đã copy sẵn.", "good")
		pcall(function()
			if type(openbrowser) == "function" then
				openbrowser(CFG.WEB)
			end
		end)
		local okOpen = pcall(function()
			local Desktop = game:GetService("StarterGui")
			Desktop:SetCore("SendNotification", {
				Title = "Chilli VKing",
				Text = "HWID đã copy — mở: " .. CFG.WEB,
				Duration = 10,
			})
		end)
		if not okOpen then
			-- im lặng
		end
		print("[Chilli VKing] Mở trang lấy key: " .. CFG.WEB)
		print("[Chilli VKing] HWID của bạn: " .. HWID)
		if #opened > 0 then
			-- không dùng
		end
	end)

	pasteBtn.MouseButton1Click:Connect(function()
		local text
		if type(getclipboard) == "function" then
			local ok, v = pcall(getclipboard)
			if ok and type(v) == "string" then
				text = v
			end
		end
		if text and text ~= "" then
			input.Text = text
			say("Đã dán từ clipboard.", "good")
		else
			say("Executor không đọc được clipboard — gõ key tay nhé.", "bad")
		end
	end)

	local checking = false

	local function doCheck(callback)
		if checking then
			return
		end
		local key = normalizeKey(input.Text)
		if not key then
			say("Key sai định dạng. Đúng dạng: CHIL-XXXX-XXXX-XXXX", "bad")
			return
		end
		checking = true
		applyBtn.Text = "Đang kiểm tra…"
		checkBtn.Text = "…"
		say("Đang kiểm tra với server…", "dim")

		task.spawn(function()
			local data, err = apiVerify(key)
			checking = false
			applyBtn.Text = "Xác nhận Key"
			checkBtn.Text = "Kiểm tra"

			if not data then
				say("Lỗi kết nối: " .. tostring(err), "bad")
				return
			end

			if data.ok then
				saveKey(key, data.expiresAt)
				say("Key hợp lệ! Còn " .. tostring(data.remainingText or formatRemaining(data.remainingMs)) .. ".", "good")
				applyBtn.Text = "Đã xác nhận ✓"
				task.delay(0.9, function()
					if callback then
						callback(key)
					end
					close(key)
				end)
			else
				local reason = data.reason
				local msg = data.message or "Key không hợp lệ."
				if reason == "hwid_mismatch" then
					msg = msg .. " HWID của bạn: " .. HWID
				elseif reason == "expired" then
					msg = msg .. " Bấm “Lấy Key” để lấy key mới."
				end
				say(msg, "bad")
			end
		end)
	end

	applyBtn.MouseButton1Click:Connect(function()
		doCheck()
	end)

	checkBtn.MouseButton1Click:Connect(function()
		doCheck(function() end)
	end)

	input.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			doCheck()
		end
	end)

	footer.Text = "Không lấy được key? Kiểm tra mạng rồi bấm “Lấy Key”."

	-- Chờ người dùng xong
	while not finished do
		task.wait(0.2)
	end

	return resultKey
end

-- ============================================================================
-- Luồng chính
-- ============================================================================

local function main()
	if CFG.DEBUG then
		warn("[Chilli VKing] CFG.DEBUG = true — BỎ QUA kiểm tra key. Nhớ đổi lại false khi phát hành!")
		return true
	end

	-- 1) Có key đã lưu? Kiểm tra nhanh với server
	local savedKey = loadKey()
	local meta = loadMeta()
	local prefill = savedKey
	local prefillMsg = nil

	if savedKey then
		local data, err = apiVerify(savedKey)
		if data and data.ok then
			print("[Chilli VKing] Key hợp lệ — còn " .. tostring(data.remainingText or formatRemaining(data.remainingMs)) .. ".")
			return true
		end

		if data then
			prefillMsg = "Key đã lưu không dùng được: " .. tostring(data.message or data.reason)
		else
			prefillMsg = "Không kiểm tra được key đã lưu (" .. tostring(err) .. "). Kiểm tra lại khi có mạng."
		end
		print("[Chilli VKing] " .. tostring(prefillMsg))
	elseif type(meta.expiresAt) == "number" and meta.expiresAt > os.time() * 1000 then
		prefillMsg = "Còn key cũ tới " .. formatRemaining(meta.expiresAt - os.time() * 1000) .. " — dán lại nếu cần."
	end

	-- 2) Mở UI để nhập key
	local key = openUI(prefill, prefillMsg)
	if not key then
		print("[Chilli VKing] Không có key hợp lệ — huỷ chạy hub.")
		return false
	end

	print("[Chilli VKing] Đã xác nhận key " .. key .. ". Đang chạy hub…")
	return true
end

-- ============================================================================
-- Kiểm tra lại định kỳ (dùng cho hub gọi lại nếu muốn)
-- ============================================================================

function _G.CHILLI_RECHECK()
	local key = loadKey()
	if not key then
		return false, "Chưa có key"
	end
	local data, err = apiVerify(key)
	if not data then
		return false, tostring(err)
	end
	return data.ok == true, data.message or data.reason
end

function _G.CHILLI_CLEAR_KEY()
	clearKey()
	return true
end

_G.FUJI_RECHECK = _G.CHILLI_RECHECK
_G.FUJI_CLEAR_KEY = _G.CHILLI_CLEAR_KEY

local ok, result = pcall(main)
if not ok then
	warn("[Chilli VKing] Lỗi trong key gate: " .. tostring(result))
	return false
end
return result
