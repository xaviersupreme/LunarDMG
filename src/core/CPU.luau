--!strict
--
local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift

type MmuInterface = {
	Read8: (addr: number) -> number,
	Write8: (addr: number, val: number) -> (),
}

type Registers = {
	A: number, F: number,
	B: number, C: number,
	D: number, E: number,
	H: number, L: number,
	SP: number,
	PC: number,
	IME: boolean,
	halted: boolean,
}

type CpuInterface = {
	reg: Registers,
	Step: () -> number,
	Reset: () -> (),
}

local flagZ: number = 0x80
local flagN: number = 0x40
local flagH: number = 0x20
local flagC: number = 0x10

local function createCPU(mmu: MmuInterface): CpuInterface
	local reg: Registers = {
		A = 0x01, F = 0xB0,
		B = 0x00, C = 0x13,
		D = 0x00, E = 0xD8,
		H = 0x01, L = 0x4D,
		SP = 0xFFFE, PC = 0x0100,
		IME = false, halted = false,
	}
	local imeEnableDelay: number = 0
	local haltBug: boolean = false

	local function getFlag(flag: number): boolean return band(reg.F, flag) ~= 0 end

	local function setFlag(flag: number, v: boolean): ()
		if v then reg.F = bor(reg.F, flag) else reg.F = band(reg.F, bnot(flag)) end
	end

	local function getAF(): number return bor(lshift(reg.A, 8), reg.F) end
	local function getBC(): number return bor(lshift(reg.B, 8), reg.C) end
	local function getDE(): number return bor(lshift(reg.D, 8), reg.E) end
	local function getHL(): number return bor(lshift(reg.H, 8), reg.L) end

	local function setBC(v: number): () reg.B = band(rshift(v, 8), 0xFF) reg.C = band(v, 0xFF) end
	local function setDE(v: number): () reg.D = band(rshift(v, 8), 0xFF) reg.E = band(v, 0xFF) end
	local function setHL(v: number): () reg.H = band(rshift(v, 8), 0xFF) reg.L = band(v, 0xFF) end

	local function aluAdd(val: number): ()
		local r: number = reg.A + val
		setFlag(flagZ, band(r, 0xFF) == 0)
		setFlag(flagN, false)
		setFlag(flagH, band(bxor(reg.A, val, r), 0x10) ~= 0)
		setFlag(flagC, r > 0xFF)
		reg.A = band(r, 0xFF)
	end

	local function aluAdc(val: number): ()
		local carry: number = getFlag(flagC) and 1 or 0
		local r: number = reg.A + val + carry
		setFlag(flagZ, band(r, 0xFF) == 0)
		setFlag(flagN, false)
		setFlag(flagH, band(bxor(reg.A, val, r), 0x10) ~= 0)
		setFlag(flagC, r > 0xFF)
		reg.A = band(r, 0xFF)
	end

	local function aluSub(val: number): ()
		local r: number = reg.A - val
		setFlag(flagZ, band(r, 0xFF) == 0)
		setFlag(flagN, true)
		setFlag(flagH, band(bxor(reg.A, val, r), 0x10) ~= 0)
		setFlag(flagC, r < 0)
		reg.A = band(r, 0xFF)
	end

	local function aluSbc(val: number): ()
		local carry: number = getFlag(flagC) and 1 or 0
		local r: number = reg.A - val - carry
		setFlag(flagZ, band(r, 0xFF) == 0)
		setFlag(flagN, true)
		setFlag(flagH, band(bxor(reg.A, val, r), 0x10) ~= 0)
		setFlag(flagC, r < 0)
		reg.A = band(r, 0xFF)
	end

	local function aluAnd(val: number): ()
		reg.A = band(reg.A, val)
		setFlag(flagZ, reg.A == 0)
		setFlag(flagN, false)
		setFlag(flagH, true)
		setFlag(flagC, false)
	end

	local function aluXor(val: number): ()
		reg.A = bxor(reg.A, val)
		setFlag(flagZ, reg.A == 0)
		setFlag(flagN, false)
		setFlag(flagH, false)
		setFlag(flagC, false)
	end

	local function aluOr(val: number): ()
		reg.A = bor(reg.A, val)
		setFlag(flagZ, reg.A == 0)
		setFlag(flagN, false)
		setFlag(flagH, false)
		setFlag(flagC, false)
	end

	local function aluCp(val: number): ()
		local r: number = reg.A - val
		setFlag(flagZ, band(r, 0xFF) == 0)
		setFlag(flagN, true)
		setFlag(flagH, band(bxor(reg.A, val, r), 0x10) ~= 0)
		setFlag(flagC, r < 0)
	end

	local function aluInc(val: number): number
		local r: number = band(val + 1, 0xFF)
		setFlag(flagZ, r == 0)
		setFlag(flagN, false)
		setFlag(flagH, band(r, 0x0F) == 0)
		return r
	end

	local function aluDec(val: number): number
		local r: number = band(val - 1, 0xFF)
		setFlag(flagZ, r == 0)
		setFlag(flagN, true)
		setFlag(flagH, band(r, 0x0F) == 0x0F)
		return r
	end

	local function stackPush(val: number): ()
		reg.SP = band(reg.SP - 2, 0xFFFF)
		mmu.Write8(reg.SP + 1, band(rshift(val, 8), 0xFF))
		mmu.Write8(reg.SP, band(val, 0xFF))
	end

	local function stackPop(): number
		local lo: number = mmu.Read8(reg.SP)
		local hi: number = mmu.Read8(reg.SP + 1)
		reg.SP = band(reg.SP + 2, 0xFFFF)
		return bor(lshift(hi, 8), lo)
	end

	local function fetch8(): number
		local v: number = mmu.Read8(reg.PC)
		if haltBug then
			haltBug = false
		else
			reg.PC = band(reg.PC + 1, 0xFFFF)
		end
		return v
	end

	local function fetch16(): number
		local lo: number = mmu.Read8(reg.PC)
		local hi: number = mmu.Read8(reg.PC + 1)
		reg.PC = band(reg.PC + 2, 0xFFFF)
		return bor(lshift(hi, 8), lo)
	end

	local function jr(cond: boolean): number
		local offset: number = fetch8()
		if cond then
			if offset > 127 then offset = offset - 256 end
			reg.PC = band(reg.PC + offset, 0xFFFF)
			return 12
		end
		return 8
	end

	local function jp(cond: boolean): number
		local addr: number = fetch16()
		if cond then reg.PC = addr return 16 end
		return 12
	end

	local function call(cond: boolean): number
		local addr: number = fetch16()
		if cond then stackPush(reg.PC) reg.PC = addr return 24 end
		return 12
	end

	local function ret(cond: boolean): number
		if cond then reg.PC = stackPop() return 20 end
		return 8
	end

	local function getReg(idx: number): number
		if idx == 0 then return reg.B
		elseif idx == 1 then return reg.C
		elseif idx == 2 then return reg.D
		elseif idx == 3 then return reg.E
		elseif idx == 4 then return reg.H
		elseif idx == 5 then return reg.L
		elseif idx == 6 then return mmu.Read8(getHL())
		else return reg.A
		end
	end

	local function setReg(idx: number, v: number): ()
		if idx == 0 then reg.B = v
		elseif idx == 1 then reg.C = v
		elseif idx == 2 then reg.D = v
		elseif idx == 3 then reg.E = v
		elseif idx == 4 then reg.H = v
		elseif idx == 5 then reg.L = v
		elseif idx == 6 then mmu.Write8(getHL(), v)
		else reg.A = v
		end
	end

	local opcodes: { [number]: () -> number } = {}

	opcodes[0x00] = function(): number return 4 end
	opcodes[0x10] = function(): number fetch8() return 4 end

	opcodes[0x01] = function(): number setBC(fetch16()) return 12 end
	opcodes[0x11] = function(): number setDE(fetch16()) return 12 end
	opcodes[0x21] = function(): number setHL(fetch16()) return 12 end
	opcodes[0x31] = function(): number reg.SP = fetch16() return 12 end

	opcodes[0x02] = function(): number mmu.Write8(getBC(), reg.A) return 8 end
	opcodes[0x12] = function(): number mmu.Write8(getDE(), reg.A) return 8 end
	opcodes[0x22] = function(): number local hl = getHL() mmu.Write8(hl, reg.A) setHL(band(hl + 1, 0xFFFF)) return 8 end
	opcodes[0x32] = function(): number local hl = getHL() mmu.Write8(hl, reg.A) setHL(band(hl - 1, 0xFFFF)) return 8 end

	opcodes[0x03] = function(): number setBC(band(getBC() + 1, 0xFFFF)) return 8 end
	opcodes[0x13] = function(): number setDE(band(getDE() + 1, 0xFFFF)) return 8 end
	opcodes[0x23] = function(): number setHL(band(getHL() + 1, 0xFFFF)) return 8 end
	opcodes[0x33] = function(): number reg.SP = band(reg.SP + 1, 0xFFFF) return 8 end

	opcodes[0x0B] = function(): number setBC(band(getBC() - 1, 0xFFFF)) return 8 end
	opcodes[0x1B] = function(): number setDE(band(getDE() - 1, 0xFFFF)) return 8 end
	opcodes[0x2B] = function(): number setHL(band(getHL() - 1, 0xFFFF)) return 8 end
	opcodes[0x3B] = function(): number reg.SP = band(reg.SP - 1, 0xFFFF) return 8 end

	opcodes[0x04] = function(): number reg.B = aluInc(reg.B) return 4 end
	opcodes[0x0C] = function(): number reg.C = aluInc(reg.C) return 4 end
	opcodes[0x14] = function(): number reg.D = aluInc(reg.D) return 4 end
	opcodes[0x1C] = function(): number reg.E = aluInc(reg.E) return 4 end
	opcodes[0x24] = function(): number reg.H = aluInc(reg.H) return 4 end
	opcodes[0x2C] = function(): number reg.L = aluInc(reg.L) return 4 end
	opcodes[0x34] = function(): number mmu.Write8(getHL(), aluInc(mmu.Read8(getHL()))) return 12 end
	opcodes[0x3C] = function(): number reg.A = aluInc(reg.A) return 4 end

	opcodes[0x05] = function(): number reg.B = aluDec(reg.B) return 4 end
	opcodes[0x0D] = function(): number reg.C = aluDec(reg.C) return 4 end
	opcodes[0x15] = function(): number reg.D = aluDec(reg.D) return 4 end
	opcodes[0x1D] = function(): number reg.E = aluDec(reg.E) return 4 end
	opcodes[0x25] = function(): number reg.H = aluDec(reg.H) return 4 end
	opcodes[0x2D] = function(): number reg.L = aluDec(reg.L) return 4 end
	opcodes[0x35] = function(): number mmu.Write8(getHL(), aluDec(mmu.Read8(getHL()))) return 12 end
	opcodes[0x3D] = function(): number reg.A = aluDec(reg.A) return 4 end

	opcodes[0x06] = function(): number reg.B = fetch8() return 8 end
	opcodes[0x0E] = function(): number reg.C = fetch8() return 8 end
	opcodes[0x16] = function(): number reg.D = fetch8() return 8 end
	opcodes[0x1E] = function(): number reg.E = fetch8() return 8 end
	opcodes[0x26] = function(): number reg.H = fetch8() return 8 end
	opcodes[0x2E] = function(): number reg.L = fetch8() return 8 end
	opcodes[0x36] = function(): number mmu.Write8(getHL(), fetch8()) return 12 end
	opcodes[0x3E] = function(): number reg.A = fetch8() return 8 end

	opcodes[0x07] = function(): number
		local b7: number = band(rshift(reg.A, 7), 1)
		reg.A = band(bor(lshift(reg.A, 1), b7), 0xFF)
		setFlag(flagZ, false) setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, b7 == 1)
		return 4
	end
	opcodes[0x0F] = function(): number
		local b0: number = band(reg.A, 1)
		reg.A = band(bor(lshift(b0, 7), rshift(reg.A, 1)), 0xFF)
		setFlag(flagZ, false) setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, b0 == 1)
		return 4
	end
	opcodes[0x17] = function(): number
		local carry: number = getFlag(flagC) and 1 or 0
		local b7: number = band(rshift(reg.A, 7), 1)
		reg.A = band(bor(lshift(reg.A, 1), carry), 0xFF)
		setFlag(flagZ, false) setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, b7 == 1)
		return 4
	end
	opcodes[0x1F] = function(): number
		local carry: number = getFlag(flagC) and 1 or 0
		local b0: number = band(reg.A, 1)
		reg.A = band(bor(lshift(carry, 7), rshift(reg.A, 1)), 0xFF)
		setFlag(flagZ, false) setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, b0 == 1)
		return 4
	end

	opcodes[0x27] = function(): number
		local a: number = reg.A
		local adj: number = 0
		if not getFlag(flagN) then
			if getFlag(flagH) or band(a, 0x0F) > 9 then adj = bor(adj, 0x06) end
			if getFlag(flagC) or a > 0x99 then adj = bor(adj, 0x60) end
			a = band(a + adj, 0xFF)
		else
			if getFlag(flagH) then adj = bor(adj, 0x06) end
			if getFlag(flagC) then adj = bor(adj, 0x60) end
			a = band(a - adj, 0xFF)
		end
		setFlag(flagZ, a == 0) setFlag(flagN, getFlag(flagN)) setFlag(flagH, false) setFlag(flagC, adj >= 0x60)
		reg.A = a
		return 4
	end

	opcodes[0x08] = function(): number
		local addr: number = fetch16()
		mmu.Write8(addr, band(reg.SP, 0xFF))
		mmu.Write8(addr + 1, band(rshift(reg.SP, 8), 0xFF))
		return 20
	end

	opcodes[0x09] = function(): number
		local hl = getHL() local r = hl + getBC()
		setFlag(flagN, false) setFlag(flagH, band(bxor(hl, getBC(), r), 0x1000) ~= 0) setFlag(flagC, r > 0xFFFF)
		setHL(band(r, 0xFFFF)) return 8
	end
	opcodes[0x19] = function(): number
		local hl = getHL() local r = hl + getDE()
		setFlag(flagN, false) setFlag(flagH, band(bxor(hl, getDE(), r), 0x1000) ~= 0) setFlag(flagC, r > 0xFFFF)
		setHL(band(r, 0xFFFF)) return 8
	end
	opcodes[0x29] = function(): number
		local hl = getHL() local r = hl + hl
		setFlag(flagN, false) setFlag(flagH, band(bxor(hl, hl, r), 0x1000) ~= 0) setFlag(flagC, r > 0xFFFF)
		setHL(band(r, 0xFFFF)) return 8
	end
	opcodes[0x39] = function(): number
		local hl = getHL() local r = hl + reg.SP
		setFlag(flagN, false) setFlag(flagH, band(bxor(hl, reg.SP, r), 0x1000) ~= 0) setFlag(flagC, r > 0xFFFF)
		setHL(band(r, 0xFFFF)) return 8
	end

	opcodes[0xE8] = function(): number
		local off: number = fetch8()
		if off > 127 then off = off - 256 end
		local r: number = reg.SP + off
		setFlag(flagZ, false) setFlag(flagN, false)
		setFlag(flagH, band(bxor(reg.SP, off, r), 0x10) ~= 0)
		setFlag(flagC, band(bxor(reg.SP, off, r), 0x100) ~= 0)
		reg.SP = band(r, 0xFFFF) return 16
	end
	opcodes[0xF8] = function(): number
		local off: number = fetch8()
		if off > 127 then off = off - 256 end
		local r: number = reg.SP + off
		setFlag(flagZ, false) setFlag(flagN, false)
		setFlag(flagH, band(bxor(reg.SP, off, r), 0x10) ~= 0)
		setFlag(flagC, band(bxor(reg.SP, off, r), 0x100) ~= 0)
		setHL(band(r, 0xFFFF)) return 12
	end
	opcodes[0xF9] = function(): number reg.SP = getHL() return 8 end

	opcodes[0x0A] = function(): number reg.A = mmu.Read8(getBC()) return 8 end
	opcodes[0x1A] = function(): number reg.A = mmu.Read8(getDE()) return 8 end
	opcodes[0x2A] = function(): number local hl = getHL() reg.A = mmu.Read8(hl) setHL(band(hl + 1, 0xFFFF)) return 8 end
	opcodes[0x3A] = function(): number local hl = getHL() reg.A = mmu.Read8(hl) setHL(band(hl - 1, 0xFFFF)) return 8 end

	opcodes[0x18] = function(): number return jr(true) end
	opcodes[0x20] = function(): number return jr(not getFlag(flagZ)) end
	opcodes[0x28] = function(): number return jr(getFlag(flagZ)) end
	opcodes[0x30] = function(): number return jr(not getFlag(flagC)) end
	opcodes[0x38] = function(): number return jr(getFlag(flagC)) end

	opcodes[0xC2] = function(): number return jp(not getFlag(flagZ)) end
	opcodes[0xC3] = function(): number return jp(true) end
	opcodes[0xCA] = function(): number return jp(getFlag(flagZ)) end
	opcodes[0xD2] = function(): number return jp(not getFlag(flagC)) end
	opcodes[0xDA] = function(): number return jp(getFlag(flagC)) end
	opcodes[0xE9] = function(): number reg.PC = getHL() return 4 end

	opcodes[0xC4] = function(): number return call(not getFlag(flagZ)) end
	opcodes[0xCC] = function(): number return call(getFlag(flagZ)) end
	opcodes[0xCD] = function(): number return call(true) end
	opcodes[0xD4] = function(): number return call(not getFlag(flagC)) end
	opcodes[0xDC] = function(): number return call(getFlag(flagC)) end

	opcodes[0xC0] = function(): number return ret(not getFlag(flagZ)) end
	opcodes[0xC8] = function(): number return ret(getFlag(flagZ)) end
	opcodes[0xC9] = function(): number reg.PC = stackPop() return 16 end
	opcodes[0xD0] = function(): number return ret(not getFlag(flagC)) end
	opcodes[0xD8] = function(): number return ret(getFlag(flagC)) end
	opcodes[0xD9] = function(): number reg.PC = stackPop() imeEnableDelay = 0 reg.IME = true return 16 end

	opcodes[0xC1] = function(): number setBC(stackPop()) return 12 end
	opcodes[0xD1] = function(): number setDE(stackPop()) return 12 end
	opcodes[0xE1] = function(): number setHL(stackPop()) return 12 end
	opcodes[0xF1] = function(): number local v = stackPop() reg.A = band(rshift(v, 8), 0xFF) reg.F = band(v, 0xF0) return 12 end
	opcodes[0xC5] = function(): number stackPush(getBC()) return 16 end
	opcodes[0xD5] = function(): number stackPush(getDE()) return 16 end
	opcodes[0xE5] = function(): number stackPush(getHL()) return 16 end
	opcodes[0xF5] = function(): number stackPush(getAF()) return 16 end

	opcodes[0xE0] = function(): number mmu.Write8(0xFF00 + fetch8(), reg.A) return 12 end
	opcodes[0xF0] = function(): number reg.A = mmu.Read8(0xFF00 + fetch8()) return 12 end
	opcodes[0xE2] = function(): number mmu.Write8(0xFF00 + reg.C, reg.A) return 8 end
	opcodes[0xF2] = function(): number reg.A = mmu.Read8(0xFF00 + reg.C) return 8 end
	opcodes[0xEA] = function(): number mmu.Write8(fetch16(), reg.A) return 16 end
	opcodes[0xFA] = function(): number reg.A = mmu.Read8(fetch16()) return 16 end

	opcodes[0x2F] = function(): number reg.A = band(bnot(reg.A), 0xFF) setFlag(flagN, true) setFlag(flagH, true) return 4 end
	opcodes[0x37] = function(): number setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, true) return 4 end
	opcodes[0x3F] = function(): number setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, not getFlag(flagC)) return 4 end
	opcodes[0xF3] = function(): number imeEnableDelay = 0 reg.IME = false return 4 end
	opcodes[0xFB] = function(): number imeEnableDelay = 2 return 4 end
	opcodes[0x76] = function(): number
		local pending: number = band(mmu.Read8(0xFFFF), band(mmu.Read8(0xFF0F), 0x1F))
		if not reg.IME and pending ~= 0 then
			haltBug = true
			return 4
		end
		reg.halted = true
		return 4
	end

	for dst = 0, 7 do
		for src = 0, 7 do
			local op: number = 0x40 + dst * 8 + src
			if op ~= 0x76 then
				local d: number = dst
				local s: number = src
				local cost: number = (s == 6 or d == 6) and 8 or 4
				opcodes[op] = function(): number setReg(d, getReg(s)) return cost end
			end
		end
	end

	local aluDispatch: { (v: number) -> () } = { aluAdd, aluAdc, aluSub, aluSbc, aluAnd, aluXor, aluOr, aluCp }
	for group = 0, 7 do
		for src = 0, 7 do
			local op: number = 0x80 + group * 8 + src
			local fn = aluDispatch[group + 1]
			local s: number = src
			local cost: number = s == 6 and 8 or 4
			opcodes[op] = function(): number fn(getReg(s)) return cost end
		end
	end

	local imm8Alu: { [number]: (v: number) -> () } = {
		[0xC6] = aluAdd, [0xCE] = aluAdc, [0xD6] = aluSub, [0xDE] = aluSbc,
		[0xE6] = aluAnd, [0xEE] = aluXor, [0xF6] = aluOr, [0xFE] = aluCp,
	}
	for op, fn in imm8Alu do
		local f = fn
		opcodes[op] = function(): number f(fetch8()) return 8 end
	end

	local rstVectors: { [number]: number } = {
		[0xC7] = 0x00, [0xCF] = 0x08, [0xD7] = 0x10, [0xDF] = 0x18,
		[0xE7] = 0x20, [0xEF] = 0x28, [0xF7] = 0x30, [0xFF] = 0x38,
	}
	for op, vec in rstVectors do
		local v: number = vec
		opcodes[op] = function(): number
			stackPush(reg.PC) reg.PC = v return 16
		end
	end

	local function cbRlc(v: number): number
		local b7: number = band(rshift(v, 7), 1)
		local r: number = band(bor(lshift(v, 1), b7), 0xFF)
		setFlag(flagZ, r == 0) setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, b7 == 1)
		return r
	end
	local function cbRrc(v: number): number
		local b0: number = band(v, 1)
		local r: number = band(bor(lshift(b0, 7), rshift(v, 1)), 0xFF)
		setFlag(flagZ, r == 0) setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, b0 == 1)
		return r
	end
	local function cbRl(v: number): number
		local carry: number = getFlag(flagC) and 1 or 0
		local b7: number = band(rshift(v, 7), 1)
		local r: number = band(bor(lshift(v, 1), carry), 0xFF)
		setFlag(flagZ, r == 0) setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, b7 == 1)
		return r
	end
	local function cbRr(v: number): number
		local carry: number = getFlag(flagC) and 1 or 0
		local b0: number = band(v, 1)
		local r: number = band(bor(lshift(carry, 7), rshift(v, 1)), 0xFF)
		setFlag(flagZ, r == 0) setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, b0 == 1)
		return r
	end
	local function cbSla(v: number): number
		local b7: number = band(rshift(v, 7), 1)
		local r: number = band(lshift(v, 1), 0xFF)
		setFlag(flagZ, r == 0) setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, b7 == 1)
		return r
	end
	local function cbSra(v: number): number
		local b0: number = band(v, 1)
		local r: number = bor(band(v, 0x80), rshift(v, 1))
		setFlag(flagZ, r == 0) setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, b0 == 1)
		return r
	end
	local function cbSwap(v: number): number
		local r: number = bor(lshift(band(v, 0x0F), 4), rshift(v, 4))
		setFlag(flagZ, r == 0) setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, false)
		return r
	end
	local function cbSrl(v: number): number
		local b0: number = band(v, 1)
		local r: number = rshift(v, 1)
		setFlag(flagZ, r == 0) setFlag(flagN, false) setFlag(flagH, false) setFlag(flagC, b0 == 1)
		return r
	end

	local cbRots: { (v: number) -> number } = { cbRlc, cbRrc, cbRl, cbRr, cbSla, cbSra, cbSwap, cbSrl }
	local cbOpcodes: { [number]: () -> number } = {}

	for grp = 0, 7 do
		for ri = 0, 7 do
			local op: number = grp * 8 + ri
			local fn = cbRots[grp + 1]
			local s: number = ri
			local cost: number = s == 6 and 16 or 8
			cbOpcodes[op] = function(): number setReg(s, fn(getReg(s))) return cost end
		end
	end

	for bitNum = 0, 7 do
		for ri = 0, 7 do
			local s: number = ri
			local mask: number = lshift(1, bitNum)
			local bitOp: number = 0x40 + bitNum * 8 + ri
			local resOp: number = 0x80 + bitNum * 8 + ri
			local setOp: number = 0xC0 + bitNum * 8 + ri
			local bCost: number = s == 6 and 12 or 8
			local rwCost: number = s == 6 and 16 or 8
			cbOpcodes[bitOp] = function(): number
				setFlag(flagZ, band(getReg(s), mask) == 0) setFlag(flagN, false) setFlag(flagH, true)
				return bCost
			end
			cbOpcodes[resOp] = function(): number setReg(s, band(getReg(s), bnot(mask))) return rwCost end
			cbOpcodes[setOp] = function(): number setReg(s, bor(getReg(s), mask)) return rwCost end
		end
	end

	opcodes[0xCB] = function(): number
		local sub: number = fetch8()
		local h = cbOpcodes[sub]
		if h then return h() end
		return 8
	end

	local intVectors: { number } = { 0x0040, 0x0048, 0x0050, 0x0058, 0x0060 }

	local function commitImeDelay(): ()
		if imeEnableDelay <= 0 then return end
		imeEnableDelay = imeEnableDelay - 1
		if imeEnableDelay == 0 then reg.IME = true end
	end

	local function handleInterrupts(): number
		local ie: number = mmu.Read8(0xFFFF)
		local ifl: number = mmu.Read8(0xFF0F)
		local pending: number = band(ie, band(ifl, 0x1F))
		if pending == 0 then return 0 end
		if reg.halted then reg.halted = false end
		if not reg.IME then return 0 end
		for i = 0, 4 do
			local bit: number = lshift(1, i)
			if band(pending, bit) ~= 0 then
				imeEnableDelay = 0
				haltBug = false
				reg.IME = false
				mmu.Write8(0xFF0F, band(ifl, bnot(bit)))
				stackPush(reg.PC)
				reg.PC = intVectors[i + 1]
				return 20
			end
		end
		return 0
	end

	local function Reset(): ()
		reg.A = 0x01 reg.F = 0xB0
		reg.B = 0x00 reg.C = 0x13
		reg.D = 0x00 reg.E = 0xD8
		reg.H = 0x01 reg.L = 0x4D
		reg.SP = 0xFFFE
		reg.PC = 0x0100
		imeEnableDelay = 0
		haltBug = false
		reg.IME = false
		reg.halted = false
	end

	local function Step(): number
		local ic: number = handleInterrupts()
		if ic > 0 then return ic end
		if reg.halted then
			commitImeDelay()
			return 4
		end
		local opcode: number = fetch8()
		local h = opcodes[opcode]
		local cycles: number = h and h() or 4
		commitImeDelay()
		return cycles
	end

	return { reg = reg, Step = Step, Reset = Reset }
end

return createCPU
