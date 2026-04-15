--!strict
--
local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local lshift = bit32.lshift
local rshift = bit32.rshift

type MmuInterface = {
	Read8: (addr: number) -> number,
	Write8: (addr: number, val: number) -> (),
	Read16: (addr: number) -> number,
	Write16: (addr: number, val: number) -> (),
	LoadROM: (data: buffer, dataLen: number) -> (),
	Tick: (cycles: number) -> (),
	SetButtonPressed: (button: string, pressed: boolean) -> (),
	GetVramWrites: () -> number,
	HasBatterySave: () -> boolean,
	ImportSaveData: (data: string) -> (),
	ExportSaveData: () -> string?,
	IsSaveDirty: () -> boolean,
	ClearSaveDirty: () -> (),
}

type MbcKind = "ROM" | "MBC1" | "MBC3"

type ApuRef = {
	Read8: (addr: number) -> number,
	Write8: (addr: number, val: number) -> (),
}

local function createMMU(apu: ApuRef?): MmuInterface
	local mem: buffer = buffer.create(65536)
	local extRam: buffer = buffer.create(0x8000)
	local romData: buffer = nil :: any
	local romDataLen: number = 0
	local cartType: number = 0x00
	local mbcKind: MbcKind = "ROM"
	local extRamSize: number = 0
	local romBankLo: number = 1
	local romBankHi: number = 0
	local ramBank: number = 0
	local mbcMode: number = 0
	local ramEnabled: boolean = false
	local vramWrites: number = 0
	local joypSelect: number = 0x00
	local divCounter: number = 0
	local timerCounter: number = 0
	local saveDirty: boolean = false
	local buttonState: { [string]: boolean } = {
		right = false,
		left = false,
		up = false,
		down = false,
		a = false,
		b = false,
		select = false,
		start = false,
	}

	local function detectMbcKind(nextCartType: number): MbcKind
		if nextCartType == 0x01 or nextCartType == 0x02 or nextCartType == 0x03 then
			return "MBC1"
		elseif nextCartType >= 0x0F and nextCartType <= 0x13 then
			return "MBC3"
		end
		return "ROM"
	end

	local function getExtRamSize(ramSizeCode: number): number
		if ramSizeCode == 0x01 then
			return 0x0800
		elseif ramSizeCode == 0x02 then
			return 0x2000
		elseif ramSizeCode == 0x03 then
			return 0x8000
		elseif ramSizeCode == 0x04 then
			return 0x20000
		elseif ramSizeCode == 0x05 then
			return 0x10000
		end
		return 0
	end

	local function hasBatterySaveForCart(nextCartType: number): boolean
		return nextCartType == 0x03
			or nextCartType == 0x06
			or nextCartType == 0x09
			or nextCartType == 0x0D
			or nextCartType == 0x0F
			or nextCartType == 0x10
			or nextCartType == 0x13
			or nextCartType == 0x1B
			or nextCartType == 0x1E
	end

	local function getRomBankCount(): number
		return math.max(1, math.ceil(romDataLen / 0x4000))
	end

	local function normalizeRomBank(bank: number): number
		local romBankCount: number = getRomBankCount()
		if romBankCount <= 1 then
			return 0
		end
		bank = bank % romBankCount
		if bank == 0 then
			bank = 1
		end
		return bank
	end

	local function getFixedRomBank(): number
		if mbcKind == "MBC1" and mbcMode == 1 then
			return normalizeRomBank(lshift(romBankHi, 5))
		end
		return 0
	end

	local function getSwitchRomBank(): number
		if mbcKind == "MBC1" then
			return normalizeRomBank(bor(lshift(romBankHi, 5), romBankLo))
		elseif mbcKind == "MBC3" then
			return normalizeRomBank(romBankLo)
		end
		return normalizeRomBank(1)
	end

	local function readRom(offset: number): number
		if romData ~= nil and offset >= 0 and offset < romDataLen then
			return buffer.readu8(romData, offset)
		end
		return 0xFF
	end

	local function resolveExtRamOffset(addr: number): number?
		if not ramEnabled or extRamSize == 0 then
			return nil
		end

		local bank: number = 0
		if mbcKind == "MBC1" then
			bank = mbcMode == 1 and ramBank or 0
		elseif mbcKind == "MBC3" then
			if ramBank > 0x03 then
				return nil
			end
			bank = ramBank
		end

		local offset: number = bank * 0x2000 + (addr - 0xA000)
		if offset < 0 or offset >= extRamSize then
			return nil
		end
		return offset
	end

	local function syncDivRegister(): ()
		buffer.writeu8(mem, 0xFF04, band(rshift(divCounter, 8), 0xFF))
	end

	local function requestInterrupt(mask: number): ()
		buffer.writeu8(mem, 0xFF0F, bor(buffer.readu8(mem, 0xFF0F), mask))
	end

	local function readJoyp(): number
		local lowNibble: number = 0x0F
		if band(joypSelect, 0x10) == 0 then
			if buttonState.right then lowNibble = band(lowNibble, 0x0E) end
			if buttonState.left then lowNibble = band(lowNibble, 0x0D) end
			if buttonState.up then lowNibble = band(lowNibble, 0x0B) end
			if buttonState.down then lowNibble = band(lowNibble, 0x07) end
		end
		if band(joypSelect, 0x20) == 0 then
			if buttonState.a then lowNibble = band(lowNibble, 0x0E) end
			if buttonState.b then lowNibble = band(lowNibble, 0x0D) end
			if buttonState.select then lowNibble = band(lowNibble, 0x0B) end
			if buttonState.start then lowNibble = band(lowNibble, 0x07) end
		end
		return bor(0xC0, joypSelect, lowNibble)
	end

	local function Read8(addr: number): number
		addr = band(addr, 0xFFFF)
		if addr < 0x4000 then
			return readRom(getFixedRomBank() * 0x4000 + addr)
		elseif addr < 0x8000 then
			return readRom(getSwitchRomBank() * 0x4000 + (addr - 0x4000))
		elseif addr >= 0xA000 and addr < 0xC000 then
			local extRamOffset: number? = resolveExtRamOffset(addr)
			if extRamOffset ~= nil then
				return buffer.readu8(extRam, extRamOffset)
			end
			return 0xFF
		elseif addr == 0xFF00 then
			return readJoyp()
		elseif addr == 0xFF04 then
			syncDivRegister()
			return buffer.readu8(mem, addr)
		elseif addr >= 0xFF10 and addr <= 0xFF3F then
			if apu then return apu.Read8(addr) end
			return buffer.readu8(mem, addr)
		elseif addr >= 0xE000 and addr < 0xFE00 then
			return buffer.readu8(mem, addr - 0x2000)
		elseif addr >= 0xFEA0 and addr < 0xFF00 then
			return 0xFF
		end
		return buffer.readu8(mem, addr)
	end

	local function runOamDma(page: number): ()
		local src: number = lshift(page, 8)
		for i = 0, 0x9F do
			buffer.writeu8(mem, 0xFE00 + i, Read8(src + i))
		end
	end

	local function Write8(addr: number, val: number): ()
		addr = band(addr, 0xFFFF)
		val = band(val, 0xFF)
		if addr < 0x2000 then
			ramEnabled = band(val, 0x0F) == 0x0A
		elseif addr < 0x4000 then
			if mbcKind == "MBC1" then
				romBankLo = band(val, 0x1F)
				if romBankLo == 0 then romBankLo = 1 end
			elseif mbcKind == "MBC3" then
				romBankLo = band(val, 0x7F)
				if romBankLo == 0 then romBankLo = 1 end
			end
		elseif addr < 0x6000 then
			if mbcKind == "MBC1" then
				romBankHi = band(val, 0x03)
				ramBank = band(val, 0x03)
			elseif mbcKind == "MBC3" then
				ramBank = band(val, 0x0F)
			end
		elseif addr < 0x8000 then
			if mbcKind == "MBC1" then
				mbcMode = band(val, 0x01)
			end
		elseif addr >= 0xA000 and addr < 0xC000 then
			local extRamOffset: number? = resolveExtRamOffset(addr)
			if extRamOffset ~= nil then
				if buffer.readu8(extRam, extRamOffset) ~= val then
					saveDirty = true
					buffer.writeu8(extRam, extRamOffset, val)
				end
			end
		elseif addr == 0xFF00 then
			joypSelect = band(val, 0x30)
			buffer.writeu8(mem, addr, readJoyp())
		elseif addr == 0xFF04 then
			divCounter = 0
			buffer.writeu8(mem, addr, 0)
		elseif addr == 0xFF05 or addr == 0xFF06 or addr == 0xFF07 then
			buffer.writeu8(mem, addr, val)
		elseif addr == 0xFF46 then
			buffer.writeu8(mem, addr, val)
			runOamDma(val)
		elseif addr >= 0xFF10 and addr <= 0xFF3F then
			if apu then apu.Write8(addr, val) end
			buffer.writeu8(mem, addr, val)
		elseif addr >= 0xE000 and addr < 0xFE00 then
			buffer.writeu8(mem, addr - 0x2000, val)
		elseif addr >= 0xFEA0 and addr < 0xFF00 then
			return
		else
			if addr >= 0x8000 and addr < 0xA000 then vramWrites = vramWrites + 1 end
			buffer.writeu8(mem, addr, val)
		end
	end

	local function Read16(addr: number): number
		return bor(lshift(Read8(addr + 1), 8), Read8(addr))
	end

	local function Write16(addr: number, val: number): ()
		Write8(addr, band(val, 0xFF))
		Write8(addr + 1, band(rshift(val, 8), 0xFF))
	end

	local function LoadROM(data: buffer, dataLen: number): ()
		romData = data
		romDataLen = dataLen
		cartType = dataLen > 0x0147 and buffer.readu8(data, 0x0147) or 0x00
		mbcKind = detectMbcKind(cartType)
		extRamSize = dataLen > 0x0149 and getExtRamSize(buffer.readu8(data, 0x0149)) or 0
		romBankLo = 1
		romBankHi = 0
		ramBank = 0
		mbcMode = 0
		ramEnabled = false
		joypSelect = 0x00
		divCounter = 0
		timerCounter = 0
		saveDirty = false
		buffer.fill(extRam, 0, 0, buffer.len(extRam))
		for button, _ in buttonState do
			buttonState[button] = false
		end
		buffer.writeu8(mem, 0xFF00, readJoyp())
		buffer.writeu8(mem, 0xFF04, 0)
		buffer.writeu8(mem, 0xFF05, 0)
		buffer.writeu8(mem, 0xFF06, 0)
		buffer.writeu8(mem, 0xFF07, 0)
	end

	local function Tick(cycles: number): ()
		divCounter = band(divCounter + cycles, 0xFFFF)
		syncDivRegister()

		local tac: number = buffer.readu8(mem, 0xFF07)
		if band(tac, 0x04) == 0 then return end

		local timerPeriod: number
		local timerSelect: number = band(tac, 0x03)
		if timerSelect == 0 then
			timerPeriod = 1024
		elseif timerSelect == 1 then
			timerPeriod = 16
		elseif timerSelect == 2 then
			timerPeriod = 64
		else
			timerPeriod = 256
		end

		timerCounter = timerCounter + cycles
		while timerCounter >= timerPeriod do
			timerCounter = timerCounter - timerPeriod
			local nextTima: number = buffer.readu8(mem, 0xFF05) + 1
			if nextTima > 0xFF then
				buffer.writeu8(mem, 0xFF05, buffer.readu8(mem, 0xFF06))
				requestInterrupt(0x04)
			else
				buffer.writeu8(mem, 0xFF05, nextTima)
			end
		end
	end

	local function SetButtonPressed(button: string, pressed: boolean): ()
		local wasJoyp: number = readJoyp()
		if buttonState[button] == pressed then return end
		buttonState[button] = pressed
		local nextJoyp: number = readJoyp()
		buffer.writeu8(mem, 0xFF00, nextJoyp)
		if pressed and band(band(wasJoyp, 0x0F), bnot(band(nextJoyp, 0x0F))) ~= 0 then
			requestInterrupt(0x10)
		end
	end

	return {
		Read8 = Read8,
		Write8 = Write8,
		Read16 = Read16,
		Write16 = Write16,
		LoadROM = LoadROM,
		Tick = Tick,
		SetButtonPressed = SetButtonPressed,
		GetVramWrites = function(): number return vramWrites end,
		HasBatterySave = function(): boolean
			return extRamSize > 0 and hasBatterySaveForCart(cartType)
		end,
		ImportSaveData = function(data: string): ()
			buffer.fill(extRam, 0, 0, buffer.len(extRam))
			local limit: number = math.min(extRamSize, #data)
			for i = 1, limit do
				buffer.writeu8(extRam, i - 1, string.byte(data, i))
			end
			saveDirty = false
		end,
		ExportSaveData = function(): string?
			if extRamSize == 0 then
				return nil
			end
			local bytes: { string } = table.create(extRamSize)
			for i = 0, extRamSize - 1 do
				bytes[i + 1] = string.char(buffer.readu8(extRam, i))
			end
			return table.concat(bytes)
		end,
		IsSaveDirty = function(): boolean
			return saveDirty
		end,
		ClearSaveDirty = function(): ()
			saveDirty = false
		end,
	}
end

return createMMU
