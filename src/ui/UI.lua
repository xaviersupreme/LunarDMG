--!strict

type Theme = {
	name: string,
	palette: { Color3 },
}

type WindowInterface = {
	getOrigin: () -> Vector2,
	getPalette: () -> { Color3 },
	getPixelSize: () -> number,
	useRasterEffects: () -> boolean,
	useVsync: () -> boolean,
	getFpsCap: () -> number,
	shouldBlockInputs: () -> boolean,
	showStats: () -> boolean,
	setStatsText: (text: string) -> (),
	destroy: () -> (),
}

local function createUI(): WindowInterface
	local userInputService = game:GetService("UserInputService")
	local runService = game:GetService("RunService")

	local bezel: number = 10
	local topBarH: number = 34
	local bottomBarH: number = 18
	local outerPad: number = 4
	local buttonSize: number = 20
	local buttonInset: number = 8

	local winX: number = 72
	local winY: number = 54
	local pixelSize: number = 3
	local settingsOpen: boolean = false
	local settingsFade: number = 0
	local settingsTarget: number = 0
	local accurateRenderer: boolean = true
	local vsyncEnabled: boolean = true
	local fpsCapOptions: { number } = { 0, 30, 45, 60 }
	local fpsCapIndex: number = 4
	local blockInputs: boolean = true
	local statsEnabled: boolean = false
	local statsTextValue: string = ""

	local themes: { Theme } = {
		{
			name = "Classic",
			palette = {
				Color3.fromRGB(155, 188, 15),
				Color3.fromRGB(139, 172, 15),
				Color3.fromRGB(48, 98, 48),
				Color3.fromRGB(15, 56, 15),
			},
		},
		{
			name = "Graphite",
			palette = {
				Color3.fromRGB(227, 231, 227),
				Color3.fromRGB(167, 175, 167),
				Color3.fromRGB(94, 101, 104),
				Color3.fromRGB(39, 44, 48),
			},
		},
		{
			name = "Amber",
			palette = {
				Color3.fromRGB(255, 237, 186),
				Color3.fromRGB(232, 179, 92),
				Color3.fromRGB(171, 105, 37),
				Color3.fromRGB(83, 45, 18),
			},
		},
	}
	local themeIndex: number = 1

	local elements: { any } = {}
	local connections: { RBXScriptConnection } = {}

	local function getScreenW(): number
		return 160 * pixelSize
	end

	local function getScreenH(): number
		return 144 * pixelSize
	end

	local function getFrameW(): number
		return getScreenW() + bezel * 2
	end

	local function getFrameH(): number
		return topBarH + getScreenH() + bottomBarH + bezel
	end

	local function draw(class: string): any
		local element = Drawing.new(class)
		elements[#elements + 1] = element
		return element
	end

	local shell = draw("Square")
	local shellOutline = draw("Square")
	local topBar = draw("Square")
	local topBarAccent = draw("Square")
	local leftBezel = draw("Square")
	local rightBezel = draw("Square")
	local bottomBezel = draw("Square")
	local screenBorder = draw("Square")
	local footerAccent = draw("Square")
	local brand = draw("Text")
	local subtitle = draw("Text")
	local statsText = draw("Text")

	local settingsButton = draw("Square")
	local settingsOuter = draw("Line")
	local settingsInner = draw("Line")
	local settingsLineA = draw("Line")
	local settingsLineB = draw("Line")
	local settingsLineC = draw("Line")
	local settingsLineD = draw("Line")
	local settingsLineE = draw("Line")
	local settingsLineF = draw("Line")
	local settingsLineG = draw("Line")
	local settingsLineH = draw("Line")

	local settingsPanel = draw("Square")
	local settingsOutline = draw("Square")
	local settingsTitle = draw("Text")
	local settingsRule = draw("Square")
	local settingsRowA = draw("Square")
	local settingsRowB = draw("Square")
	local settingsRowC = draw("Square")
	local settingsRowD = draw("Square")
	local settingsRowE = draw("Square")
	local settingsRowF = draw("Square")
	local settingsLabelA = draw("Text")
	local settingsValueA = draw("Text")
	local settingsLabelB = draw("Text")
	local settingsValueB = draw("Text")
	local settingsLabelC = draw("Text")
	local settingsValueC = draw("Text")
	local settingsLabelD = draw("Text")
	local settingsValueD = draw("Text")
	local settingsLabelE = draw("Text")
	local settingsValueE = draw("Text")
	local settingsLabelF = draw("Text")
	local settingsValueF = draw("Text")
	local settingsNote = draw("Text")

	local settingRows = { settingsRowA, settingsRowB, settingsRowC, settingsRowD, settingsRowE, settingsRowF }
	local settingLabels = { settingsLabelA, settingsLabelB, settingsLabelC, settingsLabelD, settingsLabelE, settingsLabelF }
	local settingValues = { settingsValueA, settingsValueB, settingsValueC, settingsValueD, settingsValueE, settingsValueF }
	local iconLines = {
		settingsOuter,
		settingsInner,
		settingsLineA,
		settingsLineB,
		settingsLineC,
		settingsLineD,
		settingsLineE,
		settingsLineF,
		settingsLineG,
		settingsLineH,
	}

	shell.Filled = true
	shell.Color = Color3.fromRGB(191, 198, 184)
	shell.Transparency = 1
	shell.Visible = true
	shell.ZIndex = 1

	shellOutline.Filled = false
	shellOutline.Color = Color3.fromRGB(94, 104, 96)
	shellOutline.Thickness = 1
	shellOutline.Transparency = 1
	shellOutline.Visible = true
	shellOutline.ZIndex = 8

	topBar.Filled = true
	topBar.Color = Color3.fromRGB(66, 74, 86)
	topBar.Transparency = 1
	topBar.Visible = true
	topBar.ZIndex = 5

	topBarAccent.Filled = true
	topBarAccent.Color = Color3.fromRGB(138, 152, 108)
	topBarAccent.Transparency = 1
	topBarAccent.Visible = true
	topBarAccent.ZIndex = 6

	for _, bezelRef in { leftBezel, rightBezel, bottomBezel } do
		bezelRef.Filled = true
		bezelRef.Color = Color3.fromRGB(176, 183, 169)
		bezelRef.Transparency = 1
		bezelRef.Visible = true
		bezelRef.ZIndex = 4
	end

	screenBorder.Filled = false
	screenBorder.Color = Color3.fromRGB(64, 70, 60)
	screenBorder.Thickness = 1
	screenBorder.Transparency = 1
	screenBorder.Visible = true
	screenBorder.ZIndex = 7

	footerAccent.Filled = true
	footerAccent.Color = Color3.fromRGB(120, 129, 116)
	footerAccent.Transparency = 1
	footerAccent.Visible = true
	footerAccent.ZIndex = 6

	brand.Text = "LunarDMG"
	brand.Size = 15
	brand.Font = Drawing.Fonts.UI
	brand.Color = Color3.fromRGB(245, 247, 242)
	brand.Center = true
	brand.Outline = false
	brand.Transparency = 1
	brand.Visible = true
	brand.ZIndex = 7

	subtitle.Text = ""
	subtitle.Size = 11
	subtitle.Font = Drawing.Fonts.UI
	subtitle.Color = Color3.fromRGB(208, 214, 200)
	subtitle.Center = true
	subtitle.Outline = false
	subtitle.Transparency = 1
	subtitle.Visible = false
	subtitle.ZIndex = 7

	statsText.Size = 11
	statsText.Font = Drawing.Fonts.UI
	statsText.Color = Color3.fromRGB(72, 79, 70)
	statsText.Outline = false
	statsText.Transparency = 1
	statsText.Visible = false
	statsText.ZIndex = 7

	settingsButton.Filled = true
	settingsButton.Transparency = 0
	settingsButton.Visible = false
	settingsButton.ZIndex = 6

	for _, lineRef in iconLines do
		lineRef.Thickness = 1
		lineRef.Transparency = 1
		lineRef.Visible = true
		lineRef.ZIndex = 7
	end

	settingsPanel.Filled = true
	settingsPanel.Color = Color3.fromRGB(202, 208, 194)
	settingsPanel.Transparency = 0
	settingsPanel.Visible = false
	settingsPanel.ZIndex = 9

	settingsOutline.Filled = false
	settingsOutline.Color = Color3.fromRGB(76, 84, 75)
	settingsOutline.Thickness = 1
	settingsOutline.Transparency = 0
	settingsOutline.Visible = false
	settingsOutline.ZIndex = 10

	settingsTitle.Text = "Runtime"
	settingsTitle.Size = 13
	settingsTitle.Font = Drawing.Fonts.UI
	settingsTitle.Color = Color3.fromRGB(46, 52, 48)
	settingsTitle.Outline = false
	settingsTitle.Transparency = 0
	settingsTitle.Visible = false
	settingsTitle.ZIndex = 10

	settingsRule.Filled = true
	settingsRule.Color = Color3.fromRGB(120, 129, 116)
	settingsRule.Transparency = 0
	settingsRule.Visible = false
	settingsRule.ZIndex = 10

	for _, rowRef in settingRows do
		rowRef.Filled = true
		rowRef.Color = Color3.fromRGB(194, 201, 188)
		rowRef.Transparency = 0
		rowRef.Visible = false
		rowRef.ZIndex = 9
	end

	local function styleSettingsLabel(textRef: any, text: string): ()
		textRef.Text = text
		textRef.Size = 12
		textRef.Font = Drawing.Fonts.UI
		textRef.Color = Color3.fromRGB(88, 97, 87)
		textRef.Outline = false
		textRef.Transparency = 0
		textRef.Visible = false
		textRef.ZIndex = 10
	end

	local function styleSettingsValue(textRef: any): ()
		textRef.Size = 12
		textRef.Font = Drawing.Fonts.UI
		textRef.Color = Color3.fromRGB(43, 49, 45)
		textRef.Outline = false
		textRef.Transparency = 0
		textRef.Visible = false
		textRef.ZIndex = 10
	end

	styleSettingsLabel(settingsLabelA, "Renderer")
	styleSettingsValue(settingsValueA)
	styleSettingsLabel(settingsLabelB, "VSync")
	styleSettingsValue(settingsValueB)
	styleSettingsLabel(settingsLabelC, "FPS cap")
	styleSettingsValue(settingsValueC)
	styleSettingsLabel(settingsLabelD, "Block inputs")
	styleSettingsValue(settingsValueD)
	styleSettingsLabel(settingsLabelE, "Scale")
	styleSettingsValue(settingsValueE)
	styleSettingsLabel(settingsLabelF, "Palette")
	styleSettingsValue(settingsValueF)

	settingsNote.Text = "Battery saves sync automatically."
	settingsNote.Size = 10
	settingsNote.Font = Drawing.Fonts.UI
	settingsNote.Color = Color3.fromRGB(88, 97, 87)
	settingsNote.Outline = false
	settingsNote.Transparency = 0
	settingsNote.Visible = false
	settingsNote.ZIndex = 10

	local function updateSettingTexts(): ()
		local fpsCap: number = fpsCapOptions[fpsCapIndex]
		settingsValueA.Text = accurateRenderer and "Accurate" or "Fast"
		settingsValueB.Text = vsyncEnabled and "On" or "Off"
		settingsValueC.Text = fpsCap == 0 and "Off" or string.format("%d", fpsCap)
		settingsValueD.Text = blockInputs and "Enabled" or "Disabled"
		settingsValueE.Text = string.format("%dx", pixelSize)
		settingsValueF.Text = themes[themeIndex].name
		statsText.Text = statsTextValue
		statsText.Visible = statsEnabled and statsTextValue ~= ""
	end

	local function setIconAlpha(alpha: number): ()
		local color: Color3 = Color3.fromRGB(241, 244, 237):Lerp(Color3.fromRGB(34, 41, 34), alpha)
		for _, lineRef in iconLines do
			lineRef.Color = color
		end
	end

	local function applySettingsVisibility(): ()
		local visible: boolean = settingsFade > 0.02
		settingsPanel.Visible = visible
		settingsOutline.Visible = visible
		settingsTitle.Visible = visible
		settingsRule.Visible = visible
		for _, rowRef in settingRows do
			rowRef.Visible = visible
		end
		for _, textRef in settingLabels do
			textRef.Visible = visible
		end
		for _, textRef in settingValues do
			textRef.Visible = visible
		end
		settingsNote.Visible = visible

		settingsPanel.Transparency = settingsFade
		settingsOutline.Transparency = settingsFade
		settingsTitle.Transparency = settingsFade
		settingsRule.Transparency = settingsFade * 0.9
		for _, rowRef in settingRows do
			rowRef.Transparency = settingsFade * 0.88
		end
		for _, textRef in settingLabels do
			textRef.Transparency = settingsFade
		end
		for _, textRef in settingValues do
			textRef.Transparency = settingsFade
		end
		settingsNote.Transparency = settingsFade * 0.72
		setIconAlpha(settingsFade)
	end

	local function getScreenOrigin(): Vector2
		return Vector2.new(winX + bezel, winY + topBarH)
	end

	local function getSettingsRect(): (number, number, number, number)
		return winX + getFrameW() - (buttonSize + buttonInset), winY + 4, buttonSize, buttonSize
	end

	local function getSettingsPanelRect(): (number, number, number, number)
		local panelW: number = 192
		local panelH: number = 178
		return winX + getFrameW() - panelW - 12, winY + topBarH + 8, panelW, panelH
	end

	local function getSettingRowRect(index: number, panelY: number?): (number, number, number, number)
		local panelX: number, basePanelY: number, panelW: number = getSettingsPanelRect()
		local drawPanelY: number = panelY or basePanelY
		return panelX + 10, drawPanelY + 28 + (index - 1) * 21, panelW - 20, 16
	end

	local function reposition(): ()
		local screenW: number = getScreenW()
		local screenH: number = getScreenH()
		local frameW: number = getFrameW()
		local frameH: number = getFrameH()
		local outerX: number = winX - outerPad
		local outerY: number = winY - outerPad
		local screenOrigin: Vector2 = getScreenOrigin()
		local footerY: number = screenOrigin.Y + screenH
		local panelOffsetY: number = math.floor((1 - settingsFade) * -5 + 0.5)

		shell.Position = Vector2.new(outerX, outerY)
		shell.Size = Vector2.new(frameW + outerPad * 2, frameH + outerPad * 2)

		shellOutline.Position = shell.Position
		shellOutline.Size = shell.Size

		topBar.Position = Vector2.new(winX, winY)
		topBar.Size = Vector2.new(frameW, topBarH)

		topBarAccent.Position = Vector2.new(winX, winY + topBarH - 3)
		topBarAccent.Size = Vector2.new(frameW, 3)

		leftBezel.Position = Vector2.new(winX, screenOrigin.Y)
		leftBezel.Size = Vector2.new(bezel, screenH + bottomBarH)

		rightBezel.Position = Vector2.new(screenOrigin.X + screenW, screenOrigin.Y)
		rightBezel.Size = Vector2.new(bezel, screenH + bottomBarH)

		bottomBezel.Position = Vector2.new(winX, footerY)
		bottomBezel.Size = Vector2.new(frameW, bottomBarH + bezel)

		screenBorder.Position = Vector2.new(screenOrigin.X - 1, screenOrigin.Y - 1)
		screenBorder.Size = Vector2.new(screenW + 2, screenH + 2)

		footerAccent.Position = Vector2.new(winX + 12, footerY + 7)
		footerAccent.Size = Vector2.new(64, 2)

		brand.Position = Vector2.new(winX + math.floor(frameW * 0.5 + 0.5), winY + 8)
		subtitle.Position = brand.Position
		statsText.Position = Vector2.new(winX + frameW - 154, footerY + 4)

		local settingsX: number, settingsY: number = getSettingsRect()
		local settingsCenterX: number = settingsX + buttonSize * 0.5
		local settingsCenterY: number = settingsY + buttonSize * 0.5

		settingsButton.Position = Vector2.new(settingsX, settingsY)
		settingsButton.Size = Vector2.new(buttonSize, buttonSize)

		settingsOuter.From = Vector2.new(settingsCenterX - 6, settingsCenterY - 5)
		settingsOuter.To = Vector2.new(settingsCenterX + 6, settingsCenterY - 5)
		settingsInner.From = Vector2.new(settingsCenterX - 6, settingsCenterY)
		settingsInner.To = Vector2.new(settingsCenterX + 6, settingsCenterY)
		settingsLineA.From = Vector2.new(settingsCenterX - 6, settingsCenterY + 5)
		settingsLineA.To = Vector2.new(settingsCenterX + 6, settingsCenterY + 5)

		for _, lineRef in { settingsLineB, settingsLineC, settingsLineD, settingsLineE, settingsLineF, settingsLineG, settingsLineH } do
			lineRef.From = Vector2.new(settingsCenterX, settingsCenterY)
			lineRef.To = Vector2.new(settingsCenterX, settingsCenterY)
		end

		local panelX: number, panelY: number, panelW: number, panelH: number = getSettingsPanelRect()
		local panelDrawY: number = panelY + panelOffsetY
		settingsPanel.Position = Vector2.new(panelX, panelDrawY)
		settingsPanel.Size = Vector2.new(panelW, panelH)

		settingsOutline.Position = settingsPanel.Position
		settingsOutline.Size = settingsPanel.Size

		settingsTitle.Position = Vector2.new(panelX + 10, panelDrawY + 7)
		settingsRule.Position = Vector2.new(panelX + 10, panelDrawY + 23)
		settingsRule.Size = Vector2.new(panelW - 20, 1)

		for index, rowRef in settingRows do
			local rowX: number, rowY: number, rowW: number, rowH: number = getSettingRowRect(index, panelDrawY)
			rowRef.Position = Vector2.new(rowX, rowY)
			rowRef.Size = Vector2.new(rowW, rowH)
			settingLabels[index].Position = Vector2.new(rowX + 8, rowY + 2)
			settingValues[index].Position = Vector2.new(rowX + rowW - 74, rowY + 2)
		end

		settingsNote.Position = Vector2.new(panelX + 10, panelDrawY + panelH - 15)

		updateSettingTexts()
		applySettingsVisibility()
	end

	reposition()

	local dragging: boolean = false
	local dragDX: number = 0
	local dragDY: number = 0

	local function isInsideRect(pos: Vector2, x: number, y: number, w: number, h: number): boolean
		return pos.X >= x and pos.X <= x + w and pos.Y >= y and pos.Y <= y + h
	end

	local function toggleSettings(forceOpen: boolean?): ()
		if forceOpen ~= nil then
			settingsOpen = forceOpen
		else
			settingsOpen = not settingsOpen
		end
		settingsTarget = settingsOpen and 1 or 0
		if settingsOpen and settingsFade < 0.04 then
			settingsFade = 0.04
		end
		reposition()
	end

	local function cycleSetting(index: number): ()
		if index == 1 then
			accurateRenderer = not accurateRenderer
		elseif index == 2 then
			vsyncEnabled = not vsyncEnabled
		elseif index == 3 then
			fpsCapIndex = fpsCapIndex % #fpsCapOptions + 1
		elseif index == 4 then
			blockInputs = not blockInputs
		elseif index == 5 then
			pixelSize = pixelSize >= 4 and 2 or (pixelSize + 1)
		elseif index == 6 then
			themeIndex = themeIndex % #themes + 1
		end
		reposition()
	end

	connections[1] = userInputService.InputBegan:Connect(function(input: InputObject, processed: boolean): ()
		if processed then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

		local pos: Vector2 = userInputService:GetMouseLocation()
		local settingsX: number, settingsY: number, settingsW: number, settingsH: number = getSettingsRect()

		if isInsideRect(pos, settingsX, settingsY, settingsW, settingsH) then
			toggleSettings()
			return
		end

		if settingsOpen then
			for index, rowRef in settingRows do
				local rowPos: Vector2 = rowRef.Position
				local rowSize: Vector2 = rowRef.Size
				if isInsideRect(pos, rowPos.X, rowPos.Y, rowSize.X, rowSize.Y) then
					cycleSetting(index)
					return
				end
			end

			local panelPos: Vector2 = settingsPanel.Position
			local panelSize: Vector2 = settingsPanel.Size
			if not isInsideRect(pos, panelPos.X, panelPos.Y, panelSize.X, panelSize.Y) then
				toggleSettings(false)
				return
			end
		end

		if isInsideRect(pos, winX, winY, getFrameW(), topBarH) then
			dragging = true
			dragDX = pos.X - winX
			dragDY = pos.Y - winY
		end
	end)

	connections[2] = userInputService.InputChanged:Connect(function(input: InputObject): ()
		if not dragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end

		local pos: Vector2 = userInputService:GetMouseLocation()
		winX = pos.X - dragDX
		winY = pos.Y - dragDY
		reposition()
	end)

	connections[3] = userInputService.InputEnded:Connect(function(input: InputObject): ()
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if dragging then
			dragging = false
			reposition()
		end
	end)

	connections[4] = runService.Heartbeat:Connect(function(deltaTime: number): ()
		if math.abs(settingsFade - settingsTarget) < 0.001 then
			return
		end
		local alpha: number = math.min(deltaTime * 18, 1)
		settingsFade = settingsFade + (settingsTarget - settingsFade) * alpha
		if math.abs(settingsFade - settingsTarget) < 0.01 then
			settingsFade = settingsTarget
		end
		reposition()
	end)

	local function getOrigin(): Vector2
		return getScreenOrigin()
	end

	local function getPalette(): { Color3 }
		return themes[themeIndex].palette
	end

	local function getPixelSize(): number
		return pixelSize
	end

	local function useRasterEffects(): boolean
		return accurateRenderer
	end

	local function useVsync(): boolean
		return vsyncEnabled
	end

	local function getFpsCap(): number
		return fpsCapOptions[fpsCapIndex]
	end

	local function shouldBlockInputs(): boolean
		return blockInputs
	end

	local function showStats(): boolean
		return statsEnabled
	end

	local function setStatsText(text: string): ()
		statsTextValue = text
		updateSettingTexts()
	end

	local function destroy(): ()
		for _, element in elements do
			element:Remove()
		end
		for _, connection in connections do
			connection:Disconnect()
		end
	end

	return {
		getOrigin = getOrigin,
		getPalette = getPalette,
		getPixelSize = getPixelSize,
		useRasterEffects = useRasterEffects,
		useVsync = useVsync,
		getFpsCap = getFpsCap,
		shouldBlockInputs = shouldBlockInputs,
		showStats = showStats,
		setStatsText = setStatsText,
		destroy = destroy,
	}
end

return createUI
