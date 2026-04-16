--!strict

local band = bit32.band
local bor = bit32.bor

local base = "https://raw.githubusercontent.com/xaviersupreme/LunarDMG/main/src/"

local function req(name: string): any
	local url = base .. name .. ".lua?t=" .. tostring(math.random(1, 999999999))
	local fn = assert(loadstring(game:HttpGet(url)))
	local result = fn()
	return result
end

math.randomseed(os.time())

local modulePaths = req("utils/ModulePaths")

local runnerKey: string = "__LUAUBOY_MAIN__"
local sharedRunner: any = (_G :: any)[runnerKey]
if type(sharedRunner) == "table" and type(sharedRunner.stop) == "function" then
	pcall(sharedRunner.stop)
end
sharedRunner = {}
(_G :: any)[runnerKey] = sharedRunner

local createMMU = req(modulePaths.MMU)
local createUI = req(modulePaths.UI)
local createPPU = req(modulePaths.PPU)
local createCPU = req(modulePaths.CPU)

local mmu = createMMU()
local ui = createUI()
local ppu = createPPU(ui)
local cpu = createCPU(mmu)
local isRunning: boolean = true
local inputConnections: { RBXScriptConnection } = {}
local contextActionService = game:GetService("ContextActionService")
local runService = game:GetService("RunService")
local inputBlockActionName: string = "LunarDMGMainBlockInput"
local inputBlockActive: boolean = false
local defaultSaveRoot: string = "LunarDMG/saves"
local saveRootValue: any = (_G :: any).__LUNARDMG_SAVE_ROOT__
local saveRoot: string = type(saveRootValue) == "string" and saveRootValue or defaultSaveRoot
local savePath: string? = nil
local lastSaveFlush: number = 0

sharedRunner.mmu = mmu
sharedRunner.cpu = cpu
sharedRunner.ppu = ppu

ppu.InitScreen()

local blockedKeyCodes: { Enum.KeyCode } = {
	Enum.KeyCode.Right,
	Enum.KeyCode.D,
	Enum.KeyCode.Left,
	Enum.KeyCode.A,
	Enum.KeyCode.Up,
	Enum.KeyCode.W,
	Enum.KeyCode.Down,
	Enum.KeyCode.S,
	Enum.KeyCode.Z,
	Enum.KeyCode.J,
	Enum.KeyCode.X,
	Enum.KeyCode.K,
	Enum.KeyCode.RightShift,
	Enum.KeyCode.Backspace,
	Enum.KeyCode.Return,
	Enum.KeyCode.KeypadEnter,
}

local function shouldBlockInputs(): boolean
	local fn = (ui :: any).shouldBlockInputs
	if type(fn) ~= "function" then
		return false
	end
	return fn()
end

local function shouldUseVsync(): boolean
	local fn = (ui :: any).useVsync
	if type(fn) ~= "function" then
		return true
	end
	return fn()
end

local function getFpsCap(): number
	local fn = (ui :: any).getFpsCap
	if type(fn) ~= "function" then
		return 60
	end
	local value: any = fn()
	return type(value) == "number" and value or 60
end

local function sinkInputAction(): Enum.ContextActionResult
	return Enum.ContextActionResult.Sink
end

local function refreshInputBlock(): ()
	local nextState: boolean = shouldBlockInputs()
	if nextState == inputBlockActive then
		return
	end

	contextActionService:UnbindAction(inputBlockActionName)
	inputBlockActive = nextState
	if nextState then
		contextActionService:BindActionAtPriority(
			inputBlockActionName,
			sinkInputAction,
			false,
			Enum.ContextActionPriority.High.Value,
			table.unpack(blockedKeyCodes)
		)
	end
end

refreshInputBlock()

local function supportsFsWrite(): boolean
	return type(readfile) == "function" and type(writefile) == "function"
end

local function sanitizeSaveName(name: string): string
	local cleaned: string = name:gsub("[^%w%-%._ ]", "_"):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	if cleaned == "" then
		return "game"
	end
	return cleaned
end

local function ensureFolder(path: string): boolean
	if type(isfolder) == "function" and isfolder(path) then
		return true
	end
	if type(makefolder) == "function" then
		local ok: boolean = pcall(makefolder, path)
		if ok then
			return true
		end
	end
	return type(isfolder) == "function" and isfolder(path)
end

local function ensureSaveDirectory(): boolean
	local current: string = ""
	for segment in string.gmatch(saveRoot, "[^/]+") do
		current = current == "" and segment or (current .. "/" .. segment)
		if not ensureFolder(current) then
			return false
		end
	end
	return true
end

local function flushSave(force: boolean): ()
	if savePath == nil or not supportsFsWrite() then
		return
	end
	if not mmu.HasBatterySave() then
		return
	end
	if not force and not mmu.IsSaveDirty() then
		return
	end
	local saveData: string? = mmu.ExportSaveData()
	if saveData == nil then
		return
	end
	local ok: boolean = pcall(writefile, savePath, saveData)
	if ok then
		mmu.ClearSaveDirty()
		lastSaveFlush = os.clock()
	end
end

local function stopRunner(): ()
	if not isRunning then return end
	isRunning = false
	flushSave(true)
	contextActionService:UnbindAction(inputBlockActionName)
	for _, connection in inputConnections do
		connection:Disconnect()
	end
	ppu.destroy()
	ui.destroy()
	sharedRunner.mmu = nil
	sharedRunner.cpu = nil
	sharedRunner.ppu = nil
	if sharedRunner.stop == stopRunner then
		sharedRunner.stop = nil
	end
end

sharedRunner.stop = stopRunner

local function mapKeyToButton(keyCode: Enum.KeyCode): string?
	if keyCode == Enum.KeyCode.Right or keyCode == Enum.KeyCode.D then
		return "right"
	elseif keyCode == Enum.KeyCode.Left or keyCode == Enum.KeyCode.A then
		return "left"
	elseif keyCode == Enum.KeyCode.Up or keyCode == Enum.KeyCode.W then
		return "up"
	elseif keyCode == Enum.KeyCode.Down or keyCode == Enum.KeyCode.S then
		return "down"
	elseif keyCode == Enum.KeyCode.Z or keyCode == Enum.KeyCode.J then
		return "a"
	elseif keyCode == Enum.KeyCode.X or keyCode == Enum.KeyCode.K then
		return "b"
	elseif keyCode == Enum.KeyCode.RightShift or keyCode == Enum.KeyCode.Backspace then
		return "select"
	elseif keyCode == Enum.KeyCode.Return or keyCode == Enum.KeyCode.KeypadEnter then
		return "start"
	end
	return nil
end

local userInputService = game:GetService("UserInputService")
inputConnections[1] = userInputService.InputBegan:Connect(function(input: InputObject, processed: boolean): ()
	local button: string? = mapKeyToButton(input.KeyCode)
	if button == nil then return end
	if processed and not shouldBlockInputs() then return end
	mmu.SetButtonPressed(button, true)
end)
inputConnections[2] = userInputService.InputEnded:Connect(function(input: InputObject): ()
	local button: string? = mapKeyToButton(input.KeyCode)
	if button == nil then return end
	mmu.SetButtonPressed(button, false)
end)

local function initHardware(): ()
	mmu.Write8(0xFF40, 0x91)
	mmu.Write8(0xFF41, 0x85)
	mmu.Write8(0xFF42, 0x00)
	mmu.Write8(0xFF43, 0x00)
	mmu.Write8(0xFF44, 0x00)
	mmu.Write8(0xFF45, 0x00)
	mmu.Write8(0xFF04, 0x00)
	mmu.Write8(0xFF05, 0x00)
	mmu.Write8(0xFF06, 0x00)
	mmu.Write8(0xFF07, 0x00)
	mmu.Write8(0xFF0F, 0x00)
	mmu.Write8(0xFFFF, 0x00)
	mmu.Write8(0xFF47, 0xFC)
	mmu.Write8(0xFF48, 0xFF)
	mmu.Write8(0xFF49, 0xFF)
	mmu.Write8(0xFF4A, 0x00)
	mmu.Write8(0xFF4B, 0x00)
end

local function BootROM(fileName: string): ()
	local data: string = readfile(fileName)
	local len: number = #data

	local romBuf: buffer = buffer.create(len)
	for i = 1, len do
		buffer.writeu8(romBuf, i - 1, string.byte(data, i))
	end

	mmu.LoadROM(romBuf, len)
	cpu.Reset()
	initHardware()

	local romTitle: string = ""
	for i = 0x0134, 0x0142 do
		local byte: number = mmu.Read8(i)
		if byte ~= 0 then romTitle = romTitle .. string.char(byte) end
	end

	savePath = nil
	if supportsFsWrite() and ensureSaveDirectory() and mmu.HasBatterySave() then
		savePath = string.format("%s/%s.sav", saveRoot, sanitizeSaveName(romTitle ~= "" and romTitle or fileName))
		local ok: boolean, saveData: any = pcall(readfile, savePath)
		if ok and type(saveData) == "string" then
			mmu.ImportSaveData(saveData)
		end
	end

	print(string.format("[LunarDMG] '%s' | cart=0x%02X | %d bytes",
		romTitle, mmu.Read8(0x0147), len))
	print("[LunarDMG] controls: arrows/WASD, Z/X, Enter, RightShift")

	local cyclesPerFrame: number = 70224
	local cyclesPerScan: number = 456
	local cpuHz: number = 4194304
	local maxFrameCatchUp: number = cyclesPerFrame * 3

	local frameAccum: number = 0
	local cycleBudget: number = 0
	local renderCooldown: number = 0
	local captureLineStates: { [number]: any } = table.create(144)
	local renderLineStates: { [number]: any } = table.create(144)
	local prevLy: number = 0
	local prevMode: number = 0
	local prevLycMatch: boolean = false
	local vblankCount: number = 0

	local function requestStatInterrupt(): ()
		mmu.Write8(0xFF0F, bor(mmu.Read8(0xFF0F), 0x02))
	end

	local function updateLcdState(): ()
		local ly: number = math.floor(frameAccum / cyclesPerScan) % 154
		local lineCycle: number = frameAccum % cyclesPerScan
		local statCtrl: number = band(mmu.Read8(0xFF41), 0xF8)
		local mode: number

		mmu.Write8(0xFF44, ly)

		if ly >= 144 then
			mode = 1
		elseif lineCycle < 80 then
			mode = 2
		elseif lineCycle < 252 then
			mode = 3
		else
			mode = 0
		end

		if ly >= 144 and prevLy < 144 then
			mmu.Write8(0xFF0F, bor(mmu.Read8(0xFF0F), 0x01))
			vblankCount = vblankCount + 1
		end

		local lycMatch: boolean = ly == mmu.Read8(0xFF45)
		local nextStat: number = bor(statCtrl, mode)
		if lycMatch then nextStat = bor(nextStat, 0x04) end
		mmu.Write8(0xFF41, nextStat)

		if lycMatch and not prevLycMatch and band(statCtrl, 0x40) ~= 0 then
			requestStatInterrupt()
		end

		if ly < 144 and mode == 2 and (ly ~= prevLy or prevMode ~= 2) then
			captureLineStates[ly + 1] = {
				lcdc = mmu.Read8(0xFF40),
				scx = mmu.Read8(0xFF43),
				scy = mmu.Read8(0xFF42),
				wx = mmu.Read8(0xFF4B),
				wy = mmu.Read8(0xFF4A),
				bgp = mmu.Read8(0xFF47),
				obp0 = mmu.Read8(0xFF48),
				obp1 = mmu.Read8(0xFF49),
			}
		end

		if mode ~= prevMode then
			if mode == 0 and band(statCtrl, 0x08) ~= 0 then
				requestStatInterrupt()
			elseif mode == 1 and band(statCtrl, 0x10) ~= 0 then
				requestStatInterrupt()
			elseif mode == 2 and band(statCtrl, 0x20) ~= 0 then
				requestStatInterrupt()
			end
		end

		prevLy = ly
		prevMode = mode
		prevLycMatch = lycMatch
	end

	while isRunning do
		local deltaTime: number = if shouldUseVsync() then runService.RenderStepped:Wait() else runService.Heartbeat:Wait()
		local safeDelta: number = math.min(deltaTime, 0.05)
		local shouldRender: boolean = false
		local fpsCap: number = getFpsCap()

		refreshInputBlock()
		ppu.UpdatePositions()
		if fpsCap > 0 then
			renderCooldown = math.max(renderCooldown - safeDelta, 0)
		else
			renderCooldown = 0
		end

		cycleBudget = math.min(cycleBudget + safeDelta * cpuHz, maxFrameCatchUp)
		while isRunning and cycleBudget >= 4 do
			local elapsed: number = cpu.Step()
			cycleBudget = cycleBudget - elapsed
			mmu.Tick(elapsed)
			frameAccum = frameAccum + elapsed
			updateLcdState()
			if frameAccum >= cyclesPerFrame then
				frameAccum = frameAccum - cyclesPerFrame
				local nextCaptureLineStates: { [number]: any } = renderLineStates
				renderLineStates = captureLineStates
				captureLineStates = nextCaptureLineStates
				for i = 1, 144 do
					captureLineStates[i] = nil
				end
				if fpsCap <= 0 or renderCooldown <= 0 then
					shouldRender = true
					if fpsCap > 0 then
						renderCooldown = 1 / fpsCap
					end
				end
			end
		end

		if mmu.IsSaveDirty() and os.clock() - lastSaveFlush >= 1.0 then
			flushSave(false)
		end

		if shouldRender then
			local lcdc: number = mmu.Read8(0xFF40)
			if band(lcdc, 0x80) ~= 0 then
				ppu.RenderFrame(mmu, renderLineStates)
			end

			if ui.showStats() then
				local fpsCapLabel: string = fpsCap <= 0 and "uncapped" or string.format("%dfps", fpsCap)
				ui.setStatsText(string.format("FPS %d  %s  %s  %s", vblankCount % 1000, ui.useRasterEffects() and "accurate" or "fast", shouldUseVsync() and "vsync" or "free", fpsCapLabel))
			else
				ui.setStatsText("")
			end
		end
	end

	stopRunner()
end

BootROM("rom.gb")
