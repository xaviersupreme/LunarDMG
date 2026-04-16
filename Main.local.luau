--!strict

local band = bit32.band
local bor = bit32.bor

local moduleSources: { [string]: string } = {
	CPU = [===[
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

]===],
	MMU = [===[
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
			if addr >= 0x8000 and addr < 0xA000 and buffer.readu8(mem, addr) ~= val then
				vramWrites = vramWrites + 1
			end
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

]===],
	APU = [===[
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

]===],
	PPU = [===[
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

]===],
	UI = [===[
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

]===],
	ModulePaths = [===[
--!strict

local modulePaths = {
	CPU = "core/CPU",
	MMU = "core/MMU",
	PPU = "media/PPU",
	UI = "ui/UI",
}

return modulePaths

]===],
}

local function req(name: string): any
	local localModulePaths: { [string]: string } = {
		MMU = "src/core/MMU.luau",
		UI = "src/ui/UI.luau",
		PPU = "src/media/PPU.luau",
		CPU = "src/core/CPU.luau",
		APU = "src/media/APU.luau",
		ModulePaths = "src/utils/ModulePaths.luau",
	}
	local source: string? = nil
	local localPath: string? = localModulePaths[name]
	if localPath ~= nil and type(readfile) == "function" then
		local ok: boolean, result: any = pcall(readfile, localPath)
		if ok and type(result) == "string" then
			source = result
		end
	end
	if source == nil then
		source = moduleSources[name]
	end
	assert(source ~= nil, "missing module " .. name)
	local fn = assert(loadstring(source))
	local result = fn()
	assert(type(result) == "function", name .. " returned " .. type(result))
	return result
end

local runnerKey: string = "__LUAUBOY_LOCAL__"
local sharedRunner: any = (_G :: any)[runnerKey]
if type(sharedRunner) == "table" and type(sharedRunner.stop) == "function" then
	pcall(sharedRunner.stop)
end
sharedRunner = {}
(_G :: any)[runnerKey] = sharedRunner

local createMMU = req("MMU")
local createUI = req("UI")
local createPPU = req("PPU")
local createCPU = req("CPU")
local createAPU = req("APU")

local apu = createAPU()
local mmu = createMMU(apu)
local ui = createUI()
local ppu = createPPU(ui)
local cpu = createCPU(mmu)
local isRunning: boolean = true
local inputConnections: { RBXScriptConnection } = {}
local contextActionService = game:GetService("ContextActionService")
local runService = game:GetService("RunService")
local inputBlockActionName: string = "LunarDMGLocalBlockInput"
local inputBlockActive: boolean = false
local saveRoot: string = "LunarDMG/saves"
local savePath: string? = nil
local lastSaveFlush: number = 0

sharedRunner.mmu = mmu
sharedRunner.cpu = cpu
sharedRunner.ppu = ppu
sharedRunner.read8 = function(addr: number): number
	return mmu.Read8(addr)
end
sharedRunner.press = function(button: string, pressed: boolean): ()
	mmu.SetButtonPressed(button, pressed)
end
sharedRunner.snapshot = function(): { [string]: number | boolean }
	return {
		pc = cpu.reg.PC,
		sp = cpu.reg.SP,
		ime = cpu.reg.IME,
		ffb3 = mmu.Read8(0xFFB3),
		c0d7 = mmu.Read8(0xC0D7),
		da1d = mmu.Read8(0xDA1D),
		ff9f = mmu.Read8(0xFF9F),
		div = mmu.Read8(0xFF04),
		tima = mmu.Read8(0xFF05),
		tma = mmu.Read8(0xFF06),
		tac = mmu.Read8(0xFF07),
	}
end

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
	sharedRunner.read8 = nil
	sharedRunner.press = nil
	sharedRunner.snapshot = nil
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

	print(string.format("[LunarDMG Local] '%s' | cart=0x%02X | %d bytes", romTitle, mmu.Read8(0x0147), len))

	local cyclesPerFrame: number = 70224
	local cyclesPerScan: number = 456
	local cpuHz: number = 4194304
	local maxFrameCatchUp: number = cyclesPerFrame * 3
	local mmuRead8: (addr: number) -> number = mmu.Read8
	local mmuWrite8: (addr: number, val: number) -> () = mmu.Write8
	local mmuTick: (cycles: number) -> () = mmu.Tick
	local mmuIsSaveDirty: () -> boolean = mmu.IsSaveDirty
	local cpuStep: () -> number = cpu.Step
	local apuTick: (cycles: number, mmuRef: any) -> () = apu.Tick
	local ppuUpdatePositions: () -> () = ppu.UpdatePositions
	local ppuRenderFrame: (mmuRef: any, lineStates: any) -> () = ppu.RenderFrame
	local uiShowStats: () -> boolean = ui.showStats
	local uiSetStatsText: (text: string) -> () = ui.setStatsText
	local uiUseRasterEffects: () -> boolean = ui.useRasterEffects

	local frameAccum: number = 0
	local cycleBudget: number = 0
	local renderCooldown: number = 0
	local function createLineStateBuffer(): { LineState }
		local states: { LineState } = table.create(144)
		for i = 1, 144 do
			states[i] = {
				lcdc = 0x91,
				scx = 0,
				scy = 0,
				wx = 0,
				wy = 0,
				bgp = 0xFC,
				obp0 = 0xFF,
				obp1 = 0xFF,
			}
		end
		return states
	end

	local function seedLineStates(states: { LineState }): ()
		local lcdc: number = mmuRead8(0xFF40)
		local scx: number = mmuRead8(0xFF43)
		local scy: number = mmuRead8(0xFF42)
		local wx: number = mmuRead8(0xFF4B)
		local wy: number = mmuRead8(0xFF4A)
		local bgp: number = mmuRead8(0xFF47)
		local obp0: number = mmuRead8(0xFF48)
		local obp1: number = mmuRead8(0xFF49)
		for i = 1, 144 do
			local state: LineState = states[i]
			state.lcdc = lcdc
			state.scx = scx
			state.scy = scy
			state.wx = wx
			state.wy = wy
			state.bgp = bgp
			state.obp0 = obp0
			state.obp1 = obp1
		end
	end

	local captureLineStates: { LineState } = createLineStateBuffer()
	local renderLineStates: { LineState } = createLineStateBuffer()
	local prevLy: number = 0
	local prevMode: number = 0
	local prevLycMatch: boolean = false
	local prevStatCtrl: number = 0
	local vblankCount: number = 0

	local function requestStatInterrupt(): ()
		mmuWrite8(0xFF0F, bor(mmuRead8(0xFF0F), 0x02))
	end

	local function updateLcdState(): ()
		local ly: number = math.floor(frameAccum / cyclesPerScan) % 154
		local lineCycle: number = frameAccum % cyclesPerScan
		local statCtrl: number = band(mmuRead8(0xFF41), 0xF8)
		local mode: number

		if ly >= 144 then
			mode = 1
		elseif lineCycle < 80 then
			mode = 2
		elseif lineCycle < 252 then
			mode = 3
		else
			mode = 0
		end

		local lycMatch: boolean = ly == mmuRead8(0xFF45)
		if ly == prevLy and mode == prevMode and lycMatch == prevLycMatch and statCtrl == prevStatCtrl then
			return
		end

		if ly ~= prevLy then
			mmuWrite8(0xFF44, ly)
		end

		if ly >= 144 and prevLy < 144 then
			mmuWrite8(0xFF0F, bor(mmuRead8(0xFF0F), 0x01))
			vblankCount = vblankCount + 1
		end

		local nextStat: number = bor(statCtrl, mode)
		if lycMatch then nextStat = bor(nextStat, 0x04) end
		mmuWrite8(0xFF41, nextStat)

		if lycMatch and not prevLycMatch and band(statCtrl, 0x40) ~= 0 then
			requestStatInterrupt()
		end

		if ly < 144 and mode == 2 and (ly ~= prevLy or prevMode ~= 2) then
			local state: LineState = captureLineStates[ly + 1]
			state.lcdc = mmuRead8(0xFF40)
			state.scx = mmuRead8(0xFF43)
			state.scy = mmuRead8(0xFF42)
			state.wx = mmuRead8(0xFF4B)
			state.wy = mmuRead8(0xFF4A)
			state.bgp = mmuRead8(0xFF47)
			state.obp0 = mmuRead8(0xFF48)
			state.obp1 = mmuRead8(0xFF49)
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
		prevStatCtrl = statCtrl
	end

	seedLineStates(captureLineStates)
	seedLineStates(renderLineStates)

	print("[LunarDMG Local] controls: arrows/WASD, Z/X, Enter, RightShift")

	while isRunning do
		local deltaTime: number = if shouldUseVsync() then runService.RenderStepped:Wait() else runService.Heartbeat:Wait()
		local safeDelta: number = math.min(deltaTime, 0.05)
		local shouldRender: boolean = false
		local fpsCap: number = getFpsCap()

		refreshInputBlock()
		ppuUpdatePositions()
		if fpsCap > 0 then
			renderCooldown = math.max(renderCooldown - safeDelta, 0)
		else
			renderCooldown = 0
		end

		cycleBudget = math.min(cycleBudget + safeDelta * cpuHz, maxFrameCatchUp)
		while isRunning and cycleBudget >= 4 do
			local elapsed: number = cpuStep()
			cycleBudget = cycleBudget - elapsed
			mmuTick(elapsed)
			apuTick(elapsed, mmu)
			frameAccum = frameAccum + elapsed
			updateLcdState()
			if frameAccum >= cyclesPerFrame then
				frameAccum = frameAccum - cyclesPerFrame
				local nextCaptureLineStates: { LineState } = renderLineStates
				renderLineStates = captureLineStates
				captureLineStates = nextCaptureLineStates
				if fpsCap <= 0 or renderCooldown <= 0 then
					shouldRender = true
					if fpsCap > 0 then
						renderCooldown = 1 / fpsCap
					end
				end
			end
		end

		if mmuIsSaveDirty() and os.clock() - lastSaveFlush >= 1.0 then
			flushSave(false)
		end

		if shouldRender then
			local lcdcNow: number = mmuRead8(0xFF40)
			if band(lcdcNow, 0x80) ~= 0 then
				ppuRenderFrame(mmu, renderLineStates)
			end

			if uiShowStats() then
				local fpsCapLabel: string = fpsCap <= 0 and "uncapped" or string.format("%dfps", fpsCap)
				uiSetStatsText(string.format("VBlank %d  %s  %s  %s", vblankCount % 1000, uiUseRasterEffects() and "accurate" or "fast", shouldUseVsync() and "vsync" or "free", fpsCapLabel))
			else
				uiSetStatsText("")
			end
		end
	end

	stopRunner()
end

BootROM("rom.gb")






