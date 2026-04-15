--!strict

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

type UiRef = {
	getOrigin: () -> Vector2,
	getPalette: () -> { Color3 },
	getPixelSize: () -> number,
}

type MmuRef = {
	Read8: (addr: number) -> number,
}

type LineState = {
	lcdc: number,
	scx: number,
	scy: number,
	wx: number,
	wy: number,
	bgp: number,
	obp0: number,
	obp1: number,
}

type SegmentBuffer = {
	segments: { Drawing.Square },
	rects: { RectRun },
	activeCount: number,
}

type RectRun = {
	x: number,
	y: number,
	width: number,
	height: number,
	shade: number,
}

type PpuInterface = {
	InitScreen: () -> (),
	RenderFrame: (mmu: MmuRef, lineStates: { LineState? }?) -> (),
	UpdatePositions: () -> (),
	destroy: () -> (),
}

local function createPPU(ui: UiRef): PpuInterface
	local screenW: number = 160
	local screenH: number = 144
	local screenArea: number = screenW * screenH

	local frameShades: { number } = table.create(screenArea, 0)
	local bgColorIds: { number } = table.create(screenArea, 0)
	local bgTileRowColors: { number } = table.create(8, 0)
	local windowTileRowColors: { number } = table.create(8, 0)
	local spriteTileRowColors: { number } = table.create(8, 0)
	local segmentBuffers: { SegmentBuffer } = {
		{ segments = {}, rects = {}, activeCount = 0 },
		{ segments = {}, rects = {}, activeCount = 0 },
	}
	local frontBufferIndex: number = 1
	local lastOX: number = -1
	local lastOY: number = -1
	local lastPixelSize: number = -1
	local lastPaletteRef: { Color3 }? = nil

	local function getPixelIndex(x: number, y: number): number
		return y * screenW + x + 1
	end

	local function decodePalette(paletteReg: number, colorId: number): number
		return band(rshift(paletteReg, colorId * 2), 0x03)
	end

	local function getTileAddress(tileIndex: number, tileY: number, signedTiles: boolean): number
		if signedTiles then
			local signedIndex: number = tileIndex > 127 and tileIndex - 256 or tileIndex
			return 0x9000 + signedIndex * 16 + tileY * 2
		end
		return 0x8000 + tileIndex * 16 + tileY * 2
	end

	local function getTileColorId(mmu: MmuRef, tileAddr: number, bitIndex: number): number
		local lo: number = mmu.Read8(tileAddr)
		local hi: number = mmu.Read8(tileAddr + 1)
		return bor(lshift(band(rshift(hi, bitIndex), 1), 1), band(rshift(lo, bitIndex), 1))
	end

	local function getSegment(bufferRef: SegmentBuffer, index: number): Drawing.Square
		local segment = bufferRef.segments[index]
		if segment ~= nil then
			return segment
		end

		local square = Drawing.new("Square")
		square.Filled = true
		square.Visible = false
		square.Transparency = 1
		square.ZIndex = 3
		bufferRef.segments[index] = square
		return square
	end

	local function applyBufferLayout(bufferRef: SegmentBuffer, origin: Vector2, pixelSize: number, palette: { Color3 }): ()
		for i = 1, bufferRef.activeCount do
			local rect: RectRun = bufferRef.rects[i]
			local square = getSegment(bufferRef, i)
			square.Position = Vector2.new(origin.X + rect.x * pixelSize, origin.Y + rect.y * pixelSize)
			square.Size = Vector2.new(rect.width * pixelSize, rect.height * pixelSize)
			square.Color = palette[rect.shade + 1]
		end
	end

	local function drawSegments(): ()
		local origin: Vector2 = ui.getOrigin()
		local pixelSize: number = ui.getPixelSize()
		local palette: { Color3 } = ui.getPalette()
		lastOX = origin.X
		lastOY = origin.Y
		lastPixelSize = pixelSize
		lastPaletteRef = palette

		local backBufferIndex: number = frontBufferIndex == 1 and 2 or 1
		local backBuffer: SegmentBuffer = segmentBuffers[backBufferIndex]
		local rectangles: { RectRun } = {}
		local activeRuns: { [number]: RectRun } = {}

		for y = 0, screenH - 1 do
			local nextActiveRuns: { [number]: RectRun } = {}
			local x: number = 0
			while x < screenW do
				local runShade: number = frameShades[getPixelIndex(x, y)]
				local runStart: number = x
				repeat
					x = x + 1
				until x >= screenW or frameShades[getPixelIndex(x, y)] ~= runShade

				local runWidth: number = x - runStart
				local runKey: number = runStart + lshift(runWidth, 8) + lshift(runShade, 16)
				local rect: RectRun? = activeRuns[runKey]
				if rect ~= nil then
					rect.height = rect.height + 1
					nextActiveRuns[runKey] = rect
				else
					local nextRect: RectRun = {
						x = runStart,
						y = y,
						width = runWidth,
						height = 1,
						shade = runShade,
					}
					rectangles[#rectangles + 1] = nextRect
					nextActiveRuns[runKey] = nextRect
				end
			end
			activeRuns = nextActiveRuns
		end

		local segmentCount: number = #rectangles
		backBuffer.rects = rectangles
		backBuffer.activeCount = segmentCount
		applyBufferLayout(backBuffer, origin, pixelSize, palette)

		for i = 1, segmentCount do
			local square = getSegment(backBuffer, i)
			square.Visible = false
		end

		for i = segmentCount + 1, #backBuffer.segments do
			backBuffer.segments[i].Visible = false
		end

		local frontBuffer: SegmentBuffer = segmentBuffers[frontBufferIndex]
		for i = 1, frontBuffer.activeCount do
			frontBuffer.segments[i].Visible = false
		end

		for i = 1, segmentCount do
			backBuffer.segments[i].Visible = true
		end

		frontBufferIndex = backBufferIndex
	end

	local function clearFrame(shade: number): ()
		for i = 1, screenArea do
			frameShades[i] = shade
			bgColorIds[i] = 0
		end
	end

	local function getFallbackLineState(mmu: MmuRef): LineState
		return {
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

	local function renderBackground(mmu: MmuRef, lineStates: { LineState? }?): ()
		local fallbackState: LineState = getFallbackLineState(mmu)
		for y = 0, screenH - 1 do
			local lineState: LineState = (lineStates ~= nil and lineStates[y + 1] ~= nil) and (lineStates[y + 1] :: LineState) or fallbackState
			local lcdc: number = lineState.lcdc
			local bgEnable: boolean = band(lcdc, 0x01) ~= 0
			local bgMapBase: number = band(lcdc, 0x08) ~= 0 and 0x9C00 or 0x9800
			local windowMapBase: number = band(lcdc, 0x40) ~= 0 and 0x9C00 or 0x9800
			local signedTiles: boolean = band(lcdc, 0x10) == 0
			local windowEnable: boolean = band(lcdc, 0x20) ~= 0
			local scy: number = lineState.scy
			local scx: number = lineState.scx
			local wy: number = lineState.wy
			local wx: number = lineState.wx - 7
			local bgp: number = lineState.bgp
			local bgY: number = band(y + scy, 0xFF)
			local bgTileRow: number = rshift(bgY, 3)
			local bgPixelRow: number = band(bgY, 7)
			local windowY: number = y - wy
			local useWindowRow: boolean = windowEnable and windowY >= 0
			local windowTileRow: number = useWindowRow and rshift(windowY, 3) or 0
			local windowPixelRow: number = useWindowRow and band(windowY, 7) or 0
			local bgTileColCache: number = -1
			local windowTileColCache: number = -1

			for x = 0, screenW - 1 do
				local colorId: number = 0
				if bgEnable then
					local useWindow: boolean = useWindowRow and x >= wx
					if useWindow then
						local windowX: number = x - wx
						local tileCol: number = rshift(windowX, 3)
						if tileCol ~= windowTileColCache then
							windowTileColCache = tileCol
							local tileIdx: number = mmu.Read8(windowMapBase + windowTileRow * 32 + tileCol)
							local tileAddr: number = getTileAddress(tileIdx, windowPixelRow, signedTiles)
							local lo: number = mmu.Read8(tileAddr)
							local hi: number = mmu.Read8(tileAddr + 1)
							windowTileRowColors[8] = bor(lshift(band(hi, 1), 1), band(lo, 1))
							windowTileRowColors[7] = bor(lshift(band(rshift(hi, 1), 1), 1), band(rshift(lo, 1), 1))
							windowTileRowColors[6] = bor(lshift(band(rshift(hi, 2), 1), 1), band(rshift(lo, 2), 1))
							windowTileRowColors[5] = bor(lshift(band(rshift(hi, 3), 1), 1), band(rshift(lo, 3), 1))
							windowTileRowColors[4] = bor(lshift(band(rshift(hi, 4), 1), 1), band(rshift(lo, 4), 1))
							windowTileRowColors[3] = bor(lshift(band(rshift(hi, 5), 1), 1), band(rshift(lo, 5), 1))
							windowTileRowColors[2] = bor(lshift(band(rshift(hi, 6), 1), 1), band(rshift(lo, 6), 1))
							windowTileRowColors[1] = bor(lshift(band(rshift(hi, 7), 1), 1), band(rshift(lo, 7), 1))
						end
						colorId = windowTileRowColors[band(windowX, 7) + 1]
					else
						local bgX: number = band(x + scx, 0xFF)
						local tileCol: number = rshift(bgX, 3)
						if tileCol ~= bgTileColCache then
							bgTileColCache = tileCol
							local tileIdx: number = mmu.Read8(bgMapBase + bgTileRow * 32 + tileCol)
							local tileAddr: number = getTileAddress(tileIdx, bgPixelRow, signedTiles)
							local lo: number = mmu.Read8(tileAddr)
							local hi: number = mmu.Read8(tileAddr + 1)
							bgTileRowColors[8] = bor(lshift(band(hi, 1), 1), band(lo, 1))
							bgTileRowColors[7] = bor(lshift(band(rshift(hi, 1), 1), 1), band(rshift(lo, 1), 1))
							bgTileRowColors[6] = bor(lshift(band(rshift(hi, 2), 1), 1), band(rshift(lo, 2), 1))
							bgTileRowColors[5] = bor(lshift(band(rshift(hi, 3), 1), 1), band(rshift(lo, 3), 1))
							bgTileRowColors[4] = bor(lshift(band(rshift(hi, 4), 1), 1), band(rshift(lo, 4), 1))
							bgTileRowColors[3] = bor(lshift(band(rshift(hi, 5), 1), 1), band(rshift(lo, 5), 1))
							bgTileRowColors[2] = bor(lshift(band(rshift(hi, 6), 1), 1), band(rshift(lo, 6), 1))
							bgTileRowColors[1] = bor(lshift(band(rshift(hi, 7), 1), 1), band(rshift(lo, 7), 1))
						end
						colorId = bgTileRowColors[band(bgX, 7) + 1]
					end
				end

				local pixelIndex: number = getPixelIndex(x, y)
				bgColorIds[pixelIndex] = colorId
				frameShades[pixelIndex] = decodePalette(bgp, colorId)
			end
		end
	end

	local function renderSprites(mmu: MmuRef, lineStates: { LineState? }?): ()
		local fallbackState: LineState = getFallbackLineState(mmu)
		for spriteIndex = 39, 0, -1 do
			local oamBase: number = 0xFE00 + spriteIndex * 4
			local screenY: number = mmu.Read8(oamBase) - 16
			local screenX: number = mmu.Read8(oamBase + 1) - 8
			local tileIndex: number = mmu.Read8(oamBase + 2)
			local attr: number = mmu.Read8(oamBase + 3)
			local maxSpriteHeight: number = 16
			if screenX > -8 and screenX < screenW and screenY > -maxSpriteHeight and screenY < screenH then
				local xFlip: boolean = band(attr, 0x20) ~= 0
				local yFlip: boolean = band(attr, 0x40) ~= 0
				local behindBg: boolean = band(attr, 0x80) ~= 0

				for pixelY = 0, maxSpriteHeight - 1 do
					local y: number = screenY + pixelY
					if y >= 0 and y < screenH then
						local lineState: LineState = (lineStates ~= nil and lineStates[y + 1] ~= nil) and (lineStates[y + 1] :: LineState) or fallbackState
						local lcdc: number = lineState.lcdc
						if band(lcdc, 0x02) ~= 0 then
							local spriteHeight: number = band(lcdc, 0x04) ~= 0 and 16 or 8
							if pixelY < spriteHeight then
								local baseTileIndex: number = spriteHeight == 16 and band(tileIndex, 0xFE) or tileIndex
								local paletteReg: number = band(attr, 0x10) ~= 0 and lineState.obp1 or lineState.obp0
								local spriteY: number = yFlip and (spriteHeight - 1 - pixelY) or pixelY
								local spriteTile: number = baseTileIndex + rshift(spriteY, 3)
								local tileAddr: number = 0x8000 + spriteTile * 16 + band(spriteY, 7) * 2
								local lo: number = mmu.Read8(tileAddr)
								local hi: number = mmu.Read8(tileAddr + 1)
								spriteTileRowColors[8] = bor(lshift(band(hi, 1), 1), band(lo, 1))
								spriteTileRowColors[7] = bor(lshift(band(rshift(hi, 1), 1), 1), band(rshift(lo, 1), 1))
								spriteTileRowColors[6] = bor(lshift(band(rshift(hi, 2), 1), 1), band(rshift(lo, 2), 1))
								spriteTileRowColors[5] = bor(lshift(band(rshift(hi, 3), 1), 1), band(rshift(lo, 3), 1))
								spriteTileRowColors[4] = bor(lshift(band(rshift(hi, 4), 1), 1), band(rshift(lo, 4), 1))
								spriteTileRowColors[3] = bor(lshift(band(rshift(hi, 5), 1), 1), band(rshift(lo, 5), 1))
								spriteTileRowColors[2] = bor(lshift(band(rshift(hi, 6), 1), 1), band(rshift(lo, 6), 1))
								spriteTileRowColors[1] = bor(lshift(band(rshift(hi, 7), 1), 1), band(rshift(lo, 7), 1))

								for pixelX = 0, 7 do
									local x: number = screenX + pixelX
									if x >= 0 and x < screenW then
										local bitIndex: number = xFlip and (7 - pixelX) or pixelX
										local colorId: number = spriteTileRowColors[bitIndex + 1]
										if colorId ~= 0 then
											local pixelIndex: number = getPixelIndex(x, y)
											if not behindBg or bgColorIds[pixelIndex] == 0 then
												frameShades[pixelIndex] = decodePalette(paletteReg, colorId)
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	local function InitScreen(): ()
		clearFrame(0)
		drawSegments()
	end

	local function UpdatePositions(): ()
		local origin: Vector2 = ui.getOrigin()
		local pixelSize: number = ui.getPixelSize()
		local palette: { Color3 } = ui.getPalette()
		if origin.X == lastOX and origin.Y == lastOY and pixelSize == lastPixelSize and palette == lastPaletteRef then
			return
		end
		lastOX = origin.X
		lastOY = origin.Y
		lastPixelSize = pixelSize
		lastPaletteRef = palette
		applyBufferLayout(segmentBuffers[frontBufferIndex], origin, pixelSize, palette)
	end

	local function RenderFrame(mmu: MmuRef, lineStates: { LineState? }?): ()
		local lcdc: number = mmu.Read8(0xFF40)
		if band(lcdc, 0x80) == 0 then
			clearFrame(0)
			drawSegments()
			return
		end

		renderBackground(mmu, lineStates)
		renderSprites(mmu, lineStates)
		drawSegments()
	end

	local function destroy(): ()
		for _, bufferRef in segmentBuffers do
			for _, square in bufferRef.segments do
				square:Remove()
			end
		end
	end

	return {
		InitScreen = InitScreen,
		RenderFrame = RenderFrame,
		UpdatePositions = UpdatePositions,
		destroy = destroy,
	}
end

return createPPU
