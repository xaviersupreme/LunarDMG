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
	GetVramWrites: (() -> number)?,
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
	activeRuns: { [number]: RectRun },
	nextActiveRuns: { [number]: RectRun },
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
	local tileRowCount: number = 0x1800 / 2
	local paletteShades: { number } = table.create(256 * 4, 0)
	local tileRowCacheStamps: { number } = table.create(tileRowCount, -1)
	local tileRowCacheRows: { { number }? } = table.create(tileRowCount)
	local segmentBuffers: { SegmentBuffer } = {
		{ segments = {}, rects = {}, activeCount = 0, activeRuns = {}, nextActiveRuns = {} },
		{ segments = {}, rects = {}, activeCount = 0, activeRuns = {}, nextActiveRuns = {} },
	}
	local frontBufferIndex: number = 1
	local lastOX: number = -1
	local lastOY: number = -1
	local lastPixelSize: number = -1
	local lastPaletteRef: { Color3 }? = nil
	local emptyTileRow: { number } = table.create(8, 0)
	local fallbackLineState: LineState = {
		lcdc = 0x91,
		scx = 0,
		scy = 0,
		wx = 0,
		wy = 0,
		bgp = 0xFC,
		obp0 = 0xFF,
		obp1 = 0xFF,
	}

	for paletteReg = 0, 0xFF do
		local offset: number = paletteReg * 4 + 1
		paletteShades[offset] = band(paletteReg, 0x03)
		paletteShades[offset + 1] = band(rshift(paletteReg, 2), 0x03)
		paletteShades[offset + 2] = band(rshift(paletteReg, 4), 0x03)
		paletteShades[offset + 3] = band(rshift(paletteReg, 6), 0x03)
	end

	local function getTileAddress(tileIndex: number, tileY: number, signedTiles: boolean): number
		if signedTiles then
			local signedIndex: number = tileIndex > 127 and tileIndex - 256 or tileIndex
			return 0x9000 + signedIndex * 16 + tileY * 2
		end
		return 0x8000 + tileIndex * 16 + tileY * 2
	end

	local function getTileRowColors(read8: (addr: number) -> number, tileAddr: number, cacheStamp: number): { number }
		local cacheIndex: number = rshift(tileAddr - 0x8000, 1) + 1
		if cacheIndex < 1 or cacheIndex > tileRowCount then
			local lo: number = read8(tileAddr)
			local hi: number = read8(tileAddr + 1)
			return {
				bor(lshift(band(rshift(hi, 7), 1), 1), band(rshift(lo, 7), 1)),
				bor(lshift(band(rshift(hi, 6), 1), 1), band(rshift(lo, 6), 1)),
				bor(lshift(band(rshift(hi, 5), 1), 1), band(rshift(lo, 5), 1)),
				bor(lshift(band(rshift(hi, 4), 1), 1), band(rshift(lo, 4), 1)),
				bor(lshift(band(rshift(hi, 3), 1), 1), band(rshift(lo, 3), 1)),
				bor(lshift(band(rshift(hi, 2), 1), 1), band(rshift(lo, 2), 1)),
				bor(lshift(band(rshift(hi, 1), 1), 1), band(rshift(lo, 1), 1)),
				bor(lshift(band(hi, 1), 1), band(lo, 1)),
			}
		end

		local row = tileRowCacheRows[cacheIndex]
		if row == nil then
			row = table.create(8, 0)
			tileRowCacheRows[cacheIndex] = row
		end

		if tileRowCacheStamps[cacheIndex] ~= cacheStamp then
			local lo: number = read8(tileAddr)
			local hi: number = read8(tileAddr + 1)
			row[1] = bor(lshift(band(rshift(hi, 7), 1), 1), band(rshift(lo, 7), 1))
			row[2] = bor(lshift(band(rshift(hi, 6), 1), 1), band(rshift(lo, 6), 1))
			row[3] = bor(lshift(band(rshift(hi, 5), 1), 1), band(rshift(lo, 5), 1))
			row[4] = bor(lshift(band(rshift(hi, 4), 1), 1), band(rshift(lo, 4), 1))
			row[5] = bor(lshift(band(rshift(hi, 3), 1), 1), band(rshift(lo, 3), 1))
			row[6] = bor(lshift(band(rshift(hi, 2), 1), 1), band(rshift(lo, 2), 1))
			row[7] = bor(lshift(band(rshift(hi, 1), 1), 1), band(rshift(lo, 1), 1))
			row[8] = bor(lshift(band(hi, 1), 1), band(lo, 1))
			tileRowCacheStamps[cacheIndex] = cacheStamp
		end

		return row
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
		local backSegments: { Drawing.Square } = backBuffer.segments
		local rectangles: { RectRun } = backBuffer.rects
		local activeRuns: { [number]: RectRun } = backBuffer.activeRuns
		local nextActiveRuns: { [number]: RectRun } = backBuffer.nextActiveRuns
		local rectCount: number = 0

		table.clear(activeRuns)
		table.clear(nextActiveRuns)

		for y = 0, screenH - 1 do
			table.clear(nextActiveRuns)
			local x: number = 0
			local pixelIndex: number = y * screenW + 1
			while x < screenW do
				local runShade: number = frameShades[pixelIndex]
				local runStart: number = x
				repeat
					x = x + 1
					pixelIndex = pixelIndex + 1
				until x >= screenW or frameShades[pixelIndex] ~= runShade

				local runWidth: number = x - runStart
				local runKey: number = runStart + lshift(runWidth, 8) + lshift(runShade, 16)
				local rect: RectRun? = activeRuns[runKey]
				if rect ~= nil then
					rect.height = rect.height + 1
					nextActiveRuns[runKey] = rect
				else
					rectCount = rectCount + 1
					local nextRect: RectRun? = rectangles[rectCount]
					if nextRect == nil then
						nextRect = {
							x = 0,
							y = 0,
							width = 0,
							height = 0,
							shade = 0,
						}
						rectangles[rectCount] = nextRect
					end
					nextRect.x = runStart
					nextRect.y = y
					nextRect.width = runWidth
					nextRect.height = 1
					nextRect.shade = runShade
					nextActiveRuns[runKey] = nextRect
				end
			end
			local swapRuns: { [number]: RectRun } = activeRuns
			activeRuns = nextActiveRuns
			nextActiveRuns = swapRuns
		end

		backBuffer.activeRuns = activeRuns
		backBuffer.nextActiveRuns = nextActiveRuns
		backBuffer.activeCount = rectCount
		applyBufferLayout(backBuffer, origin, pixelSize, palette)

		for i = rectCount + 1, #backSegments do
			backSegments[i].Visible = false
		end

		local frontBuffer: SegmentBuffer = segmentBuffers[frontBufferIndex]
		local frontSegments: { Drawing.Square } = frontBuffer.segments
		for i = 1, frontBuffer.activeCount do
			frontSegments[i].Visible = false
		end

		for i = 1, rectCount do
			backSegments[i].Visible = true
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
		fallbackLineState.lcdc = mmu.Read8(0xFF40)
		fallbackLineState.scx = mmu.Read8(0xFF43)
		fallbackLineState.scy = mmu.Read8(0xFF42)
		fallbackLineState.wx = mmu.Read8(0xFF4B)
		fallbackLineState.wy = mmu.Read8(0xFF4A)
		fallbackLineState.bgp = mmu.Read8(0xFF47)
		fallbackLineState.obp0 = mmu.Read8(0xFF48)
		fallbackLineState.obp1 = mmu.Read8(0xFF49)
		return fallbackLineState
	end

	local function renderBackground(mmu: MmuRef, lineStates: { LineState? }?, cacheStamp: number): ()
		local read8: (addr: number) -> number = mmu.Read8
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
			local bgPaletteBase: number = bgp * 4 + 1
			local windowY: number = y - wy
			local useWindowRow: boolean = windowEnable and windowY >= 0
			local windowTileRow: number = useWindowRow and rshift(windowY, 3) or 0
			local windowPixelRow: number = useWindowRow and band(windowY, 7) or 0
			local bgTileColCache: number = -1
			local windowTileColCache: number = -1
			local bgTileRowColors: { number } = emptyTileRow
			local windowTileRowColors: { number } = emptyTileRow
			local pixelIndex: number = y * screenW + 1

			for x = 0, screenW - 1 do
				local colorId: number = 0
				if bgEnable then
					local useWindow: boolean = useWindowRow and x >= wx
					if useWindow then
						local windowX: number = x - wx
						local tileCol: number = rshift(windowX, 3)
						if tileCol ~= windowTileColCache then
							windowTileColCache = tileCol
							local tileIdx: number = read8(windowMapBase + windowTileRow * 32 + tileCol)
							local tileAddr: number = getTileAddress(tileIdx, windowPixelRow, signedTiles)
							windowTileRowColors = getTileRowColors(read8, tileAddr, cacheStamp)
						end
						colorId = windowTileRowColors[band(windowX, 7) + 1]
					else
						local bgX: number = band(x + scx, 0xFF)
						local tileCol: number = rshift(bgX, 3)
						if tileCol ~= bgTileColCache then
							bgTileColCache = tileCol
							local tileIdx: number = read8(bgMapBase + bgTileRow * 32 + tileCol)
							local tileAddr: number = getTileAddress(tileIdx, bgPixelRow, signedTiles)
							bgTileRowColors = getTileRowColors(read8, tileAddr, cacheStamp)
						end
						colorId = bgTileRowColors[band(bgX, 7) + 1]
					end
				end

				bgColorIds[pixelIndex] = colorId
				frameShades[pixelIndex] = paletteShades[bgPaletteBase + colorId]
				pixelIndex = pixelIndex + 1
			end
		end
	end

	local function renderSprites(mmu: MmuRef, lineStates: { LineState? }?, cacheStamp: number): ()
		local read8: (addr: number) -> number = mmu.Read8
		local fallbackState: LineState = getFallbackLineState(mmu)
		for spriteIndex = 39, 0, -1 do
			local oamBase: number = 0xFE00 + spriteIndex * 4
			local screenY: number = read8(oamBase) - 16
			local screenX: number = read8(oamBase + 1) - 8
			local tileIndex: number = read8(oamBase + 2)
			local attr: number = read8(oamBase + 3)
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
								local paletteBase: number = paletteReg * 4 + 1
								local spriteY: number = yFlip and (spriteHeight - 1 - pixelY) or pixelY
								local spriteTile: number = baseTileIndex + rshift(spriteY, 3)
								local tileAddr: number = 0x8000 + spriteTile * 16 + band(spriteY, 7) * 2
								local spriteTileRowColors: { number } = getTileRowColors(read8, tileAddr, cacheStamp)
								local pixelIndexBase: number = y * screenW + 1

								for pixelX = 0, 7 do
									local x: number = screenX + pixelX
									if x >= 0 and x < screenW then
										local bitIndex: number = xFlip and (7 - pixelX) or pixelX
										local colorId: number = spriteTileRowColors[bitIndex + 1]
										if colorId ~= 0 then
											local pixelIndex: number = pixelIndexBase + x
											if not behindBg or bgColorIds[pixelIndex] == 0 then
												frameShades[pixelIndex] = paletteShades[paletteBase + colorId]
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

		local cacheStamp: number = type(mmu.GetVramWrites) == "function" and mmu.GetVramWrites() or 0
		renderBackground(mmu, lineStates, cacheStamp)
		renderSprites(mmu, lineStates, cacheStamp)
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
