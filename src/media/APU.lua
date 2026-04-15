--!strict

local band = bit32.band
local bor = bit32.bor

type MmuRef = {
	Read8: (addr: number) -> number,
	Write8: (addr: number, val: number) -> (),
}

type ApuInterface = {
	Read8: (addr: number) -> number,
	Write8: (addr: number, val: number) -> (),
	Tick: (cycles: number, mmu: MmuRef) -> (),
}

local function createAPU(): ApuInterface
	local registers: { number } = table.create(0x30, 0)
	local fsTimer: number = 0
	local fsStep: number = 0
	
	local function Read8(addr: number): number
		if addr >= 0xFF10 and addr <= 0xFF3F then
			local offset = addr - 0xFF10 + 1
			if addr == 0xFF26 then
				return bor(registers[offset], 0x80)
			end
			return registers[offset] or 0xFF
		end
		return 0xFF
	end

	local function Write8(addr: number, val: number): ()
		if addr >= 0xFF10 and addr <= 0xFF3F then
			local offset = addr - 0xFF10 + 1
			if addr == 0xFF26 then
				if band(val, 0x80) == 0 then
					for i = 1, 0x16 do
						registers[i] = 0
					end
				end
			end
			registers[offset] = band(val, 0xFF)
		end
	end

	local function Tick(cycles: number, mmu: MmuRef): ()
		fsTimer = fsTimer + cycles
		if fsTimer >= 8192 then
			fsTimer = fsTimer - 8192
			fsStep = band(fsStep + 1, 7)
		end
	end

	return {
		Read8 = Read8,
		Write8 = Write8,
		Tick = Tick,
	}
end

return createAPU
