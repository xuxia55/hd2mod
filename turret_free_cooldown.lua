-- HD2-Addon: mods/dsh/turret_free_cooldown
-- 战备「次数上限 + 冷却」补丁（哨戒炮 / 炮台 / 地雷）
-- 只读定位 -> 校验 -> 备份 -> 写入 -> 回读 -> 每 5 秒复查
-- 目标表 T：id = { 次数上限, 冷却秒 }

local T = {
    -- ===== 原有 13 条（数值原样保留，要与不是这里改数字）=====
    [4239785897] = { 99,  1.0 },  -- SENTRYS. MACHINEGUN            机枪哨戒炮
    [1582497738] = { 99,  1.0 },  -- SENTRYS. MORTAR                迫击炮哨戒炮
    [623391597 ] = { 99,  1.0 },  -- SENTRYS. GATLING               加特林哨戒炮
    [854563507 ] = { 99,  1.0 },  -- SENTRYS. AUTOCANNON            自动炮哨戒炮
    [717707279 ] = { 99,  1.0 },  -- SENTRYS. ROCKET                火箭哨戒炮
    [3085503322] = { 99,  1.0 },  -- SENTRYS. MORTAR STATICFIELD    静止场迫击炮
    [2402590523] = { 99, 20.0 },  -- EMPLACEMENTS. TESLA TOWER      特斯拉塔
    [2919842659] = { 99, 30.0 },  -- EMPLACEMENTS. HMG              重机枪炮台
    [2281932031] = { 99,  1.0 },  -- EMPLACEMENTS. SHIELD RELAY     护盾中继
    [12688472  ] = { 50,  1.0 },  -- EMPLACEMENTS. AP MINE          人员雷
    [644090457 ] = { 10,  1.0 },  -- EMPLACEMENTS. GAS MINE         毒气雷
    [2239174926] = { 15,  1.0 },  -- EMPLACEMENTS. AT MINE          反坦克雷
    [2742141597] = { 20,  1.0 },  -- EMPLACEMENTS. INCENDIARY MINE  燃烧雷
    -- ===== 新增 4 条 =====
    [474724029 ] = { 99,  1.0 },  -- SENTRYS. FLAME      FLAM-40   火焰哨戒炮
    [960389145 ] = { 99,  1.0 },  -- EMPLACEMENTS. LASER  A/LAS-98  激光哨戒炮
    [3183339606] = { 99,  1.0 },  -- SENTRYS. MORTAR GAS  A/GM-17   毒气迫击炮
    [762584056 ] = { 99, 30.0 },  -- EMPLACEMENTS. AT     E/AT-12   反坦克炮台
}

local CFG = {
    type_hash = 0x30EB6399,   -- djb2("StratagemSettings")
    rec_size  = 400,
    id_off    = 4,
    uses_off  = 80,
    cd_off    = 104,          -- f32
    out_dir   = "Hd2TurretFreeCooldown",
    scan_chunk = 262144,
    scan_budget = 0.004,
    start_frame = 120,
    min_region = 65536,
    max_count  = 4096,
    recheck_frames = 300,       -- ~5s 复查
    full_rescan_frames = 36000, -- ~10min 全量兜底
    err_limit = 8,
    write_limit = 2,            -- 每次 step 最多写几条
}

local state = rawget(_G, "DshTurretFreeCooldown")
if state then return state end
state = { frames=0, phase="init", blocks={}, nblocks=0, wrote=0, backups=0, errors=0, target_total=0 }
rawset(_G, "DshTurretFreeCooldown", state)
for _ in pairs(T) do state.target_total = state.target_total + 1 end

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi or not ffi then print("[TFC] FFI 不可用"); state.phase="failed"; return state end

ffi.cdef[[
    void *GetCurrentProcess(void);
    int ReadProcessMemory(void *p, const void *a, void *b, size_t n, size_t *r);
    int WriteProcessMemory(void *p, void *a, const void *b, size_t n, size_t *r);
    size_t VirtualQuery(const void *a, void *r, size_t s);
    int VirtualProtect(void *a, size_t n, uint32_t prot, uint32_t *old);
    int CreateDirectoryA(const char *p, void *sec);
    uint32_t GetLastError(void);
    typedef struct { void *base; void *ab; uint32_t ap; uint16_t part; uint16_t res;
        size_t size; uint32_t state; uint32_t prot; uint32_t type; } TFC_MBI;
    typedef union { uint32_t u; float f; } TFC_FU;
]]

local kernel  = ffi.load("kernel32")
local process = kernel.GetCurrentProcess()

local out_dir = nil
do
    local b = os.getenv("LOCALAPPDATA")
    if b then
        local d = b .. "/" .. CFG.out_dir
        if kernel.CreateDirectoryA(d, nil) ~= 0 or kernel.GetLastError() == 183 then out_dir = d end
    end
end

local function write_file(name, text)
    if not out_dir then return false end
    local ok, f = pcall(io.open, out_dir .. "/" .. name, "w")
    if not ok or not f then return false end
    pcall(f.write, f, text); pcall(f.close, f); return true
end

local function log(m)
    print("[TFC] " .. m)
    if out_dir then
        local f = io.open(out_dir .. "/tfc.log", "a")
        if f then f:write("[frame " .. tostring(state.frames) .. "] " .. m .. "\n"); f:close() end
    end
end

local function status(head)
    local l = {}
    l[#l+1] = head
    l[#l+1] = "phase="   .. tostring(state.phase)
    l[#l+1] = "frames="  .. tostring(state.frames)
    l[#l+1] = "blocks="  .. tostring(state.nblocks)
    l[#l+1] = "targets=" .. tostring(state.target_total)
    l[#l+1] = "writes="  .. tostring(state.wrote)
    l[#l+1] = "backups=" .. tostring(state.backups)
    l[#l+1] = "errors="  .. tostring(state.errors)
    write_file("STATUS.txt", table.concat(l, "\n") .. "\n")
end

do
    local ld = rawget(_G, "CowboyBingusModLoader")
    local api = type(ld) == "table" and tonumber(ld.api) or nil
    log("loader api=" .. tostring(api or "N/A"))
end

-- ---------- 读写原语（每次调用都是只读 / 显式写）----------
local scratch = ffi.new("uint8_t[1048576]")
local cnt     = ffi.new("size_t[1]")

local function read_at(a, n)
    if type(a) ~= "number" or a < 65536 or a + n >= 0x800000000000 then return nil end
    if n <= 0 or n > 1048576 then return nil end
    local ok, r = pcall(function()
        return kernel.ReadProcessMemory(process, ffi.cast("const void *", a), scratch, n, cnt)
    end)
    if not ok or r == 0 or tonumber(cnt[0]) ~= n then return nil end
    return ffi.string(scratch, n)
end

local fu = ffi.new("TFC_FU[1]")

local function u32(s, i)
    local a,b,c,d = s:byte(i, i+3)
    if not d then return nil end
    return a + b*256 + c*65536 + d*16777216
end
local function u64(s, i)
    local lo, hi = u32(s, i), u32(s, i+4)
    if not lo or not hi or hi > 0x1FFFFF then return nil end
    return lo + hi * 4294967296
end
local function f32(s, i)
    local v = u32(s, i); if not v then return nil end
    fu[0].u = v; return fu[0].f
end
local function u32le(n) return string.char(n%256, math.floor(n/256)%256, math.floor(n/65536)%256, math.floor(n/16777216)%256) end
local function f32le(x) fu[0].f = x; local v = fu[0].u
    return u32le(v) end
local function hex(s) local p={} for i=1,#s do p[i]=string.format("%02x", s:byte(i)) end return table.concat(p) end

-- 只写"已经校验过的数据页"：只读页临时放开，写完立刻恢复保护属性
local function write_at(addr, bytes)
    if type(addr) ~= "number" or addr < 65536 then return false end
    local size = #bytes
    local mbi  = ffi.new("TFC_MBI[1]")
    local got  = tonumber(kernel.VirtualQuery(ffi.cast("const void *", addr), ffi.cast("void *", mbi), ffi.sizeof(mbi[0])))
    if got ~= 48 then return false end
    local base = tonumber(ffi.cast("uintptr_t", mbi[0].base))
    local prot = tonumber(mbi[0].prot)
    if tonumber(mbi[0].state) ~= 0x1000 or addr < base or addr + size > base + tonumber(mbi[0].size) then return false end
    if prot ~= 0x02 and prot ~= 0x04 and prot ~= 0x40 then return false end   -- 只允许 RO/RW/RWX 数据页
    local old = ffi.new("uint32_t[1]")
    local changed = false
    if prot ~= 0x04 then
        if kernel.VirtualProtect(ffi.cast("void *", addr), size, 0x04, old) == 0 then return false end
        changed = true
    end
    local ok, res = pcall(function()
        return kernel.WriteProcessMemory(process, ffi.cast("void *", addr), bytes, size, cnt)
    end)
    local done = ok and res ~= 0 and tonumber(cnt[0]) == size
    if changed then
        local u = ffi.new("uint32_t[1]")
        kernel.VirtualProtect(ffi.cast("void *", addr), size, old[0], u)
    end
    if not done then return false end
    return read_at(addr, size) == bytes          -- 回读验证
end

-- ---------- 表定位 ----------
local MAGIC = "LDLD"
local self_addr = nil
do
    local ok, p = pcall(function() return tonumber(ffi.cast("uintptr_t", ffi.cast("const char *", MAGIC))) end)
    if ok and p and p > 0 then self_addr = p end
end

local function plausible_uses(v) return v == 4294967295 or (v >= 1 and v <= 200) end
local function plausible_cd(v)   return v and v == v and v >= 0 and v <= 3600 end

-- 记录是否"像真的"：uses 与 cd 都在值域里
local function rec_ok(rec)
    local u = u32(rec, CFG.uses_off + 1)
    local c = f32(rec, CFG.cd_off + 1)
    if not plausible_uses(u) then return false end
    if not plausible_cd(c) then return false end
    local id = u32(rec, CFG.id_off + 1)
    return id ~= nil and id ~= 0
end

local function score_block(blob, count)
    local good = 0
    for i = 0, count - 1 do
        local off = i * CFG.rec_size
        local rec = blob:sub(off + 1, off + CFG.rec_size)
        if rec_ok(rec) then good = good + 1 end
    end
    return count > 0 and good / count or 0
end

local function try_block(magic)
    local head = read_at(magic, 24)
    if not head or head:sub(1,4) ~= MAGIC then return false end
    if u32(head, 5) ~= 1 or u32(head, 9) ~= CFG.type_hash then return false end
    local d = read_at(magic + 24, 16)
    if not d then return false end
    local f1, f2 = u64(d, 1), u64(d, 9)
    if not f1 or not f2 then return false end
    local cands = { {f1,f2}, {magic+24+f1,f2}, {magic+f1,f2}, {f2,f1} }
    local best = nil
    for _, c in ipairs(cands) do
        local base, count = c[1], c[2]
        if base >= 65536 and count >= 1 and count <= CFG.max_count and not state.blocks[base] then
            local blob = read_at(base, count * CFG.rec_size)
            if blob and #blob == count * CFG.rec_size then
                local sc = score_block(blob, count)
                if sc >= 0.6 and (not best or sc > best.score) then
                    best = { base = base, count = count, blob = blob, score = sc }
                end
            end
        end
    end
    if best then
        state.blocks[best.base] = best
        state.nblocks = 0
        for _ in pairs(state.blocks) do state.nblocks = state.nblocks + 1 end
        log(string.format("block base=0x%x count=%d score=%.2f", best.base, best.count, best.score))
        return true
    end
    return false
end

-- ---------- 补丁 ----------
local function patch_record(addr, id, rec)
    local t = T[id]; if not t then return 0 end
    local want_uses, want_cd = t[1], t[2]
    local cur_uses = u32(rec, CFG.uses_off + 1)
    local cur_cd   = f32(rec, CFG.cd_off + 1)
    local n = 0
    if cur_uses ~= want_uses then
        if state.backups < 64 and out_dir then
            write_file(string.format("backup_%d_%d.hex", id, addr), hex(rec) .. "\n")
            state.backups = state.backups + 1
        end
        if write_at(addr + CFG.uses_off, u32le(want_uses)) then n = n + 1 end
    end
    if cur_cd ~= want_cd then
        if write_at(addr + CFG.cd_off, f32le(want_cd)) then n = n + 1 end
    end
    if n > 0 then log(string.format("patched id=%d uses=%s->%s cd=%s->%s", id,
        tostring(cur_uses), tostring(want_uses), tostring(cur_cd), tostring(want_cd))) end
    return n
end

local function maintain_one(b)
    local blob = read_at(b.base, b.count * CFG.rec_size)
    if not blob or #blob ~= b.count * CFG.rec_size then return 0, false end
    b.blob = blob
    local n = 0
    for i = 0, b.count - 1 do
        if n >= CFG.write_limit then break end
        local off = i * CFG.rec_size
        local rec = blob:sub(off + 1, off + CFG.rec_size)
        local id  = u32(rec, CFG.id_off + 1)
        if id and T[id] then n = n + patch_record(b.base + off, id, rec) end
    end
    state.wrote = state.wrote + n
    return n, true
end

-- ---------- 扫描 ----------
local regions, ri, ro, prev = nil, 1, 0, ""
local function readable(p) return p==2 or p==4 or p==8 or p==32 or p==64 or p==128 end

local function collect_regions()
    local list, a, reg = {}, 65536, ffi.new("TFC_MBI[1]")
    local sz = ffi.sizeof(reg[0])
    while a < 2^47 do
        local ok, res = pcall(function()
            return kernel.VirtualQuery(ffi.cast("const void *", a), ffi.cast("void *", reg), sz)
        end)
        if not ok or tonumber(res) ~= sz then break end
        local st, pr = tonumber(reg[0].state), tonumber(reg[0].prot)
        local rb, rs = tonumber(ffi.cast("uintptr_t", reg[0].base)), tonumber(reg[0].size)
        if st == 4096 and readable(pr) and rs >= CFG.min_region then
            list[#list+1] = { base = rb, size = rs }
        end
        local nx = rb + rs
        if nx <= a then break end
        a = nx
    end
    table.sort(list, function(x, y) return x.size > y.size end)
    return list
end

local function scan_step()
    if not regions then regions = collect_regions(); ri, ro, prev = 1, 0, ""; return end
    local deadline = os.clock() + CFG.scan_budget
    while os.clock() < deadline do
        local r = regions[ri]
        if not r then regions = nil; return end
        local rem = r.size - ro
        if rem <= 0 then ri = ri + 1; ro, prev = 0, ""; return end
        local want = rem > CFG.scan_chunk and CFG.scan_chunk or rem
        local buf  = read_at(r.base + ro, want)
        if buf then
            local win = prev .. buf
            local from = 1
            while true do
                local i = string.find(win, MAGIC, from, true)
                if not i then break end
                local abs = r.base + ro - #prev + i - 1
                if not (self_addr and math.abs(abs - self_addr) < 4096) then
                    local ok, err = pcall(try_block, abs)
                    if not ok then
                        state.errors = state.errors + 1
                        if state.errors <= CFG.err_limit then log("hit error " .. tostring(err)) end
                    end
                end
                from = i + 1
            end
            prev = buf:sub(-2048)
        else
            prev = ""
        end
        ro = ro + want
    end
end

-- ---------- 主循环 ----------
local old = update
if type(old) ~= "function" then
    log("no update hook"); state.phase = "failed"; status("FAILED - no update hook"); return state
end

local function tick()
    state.frames = state.frames + 1

    if state.phase == "init" then
        if state.frames >= CFG.start_frame then state.phase = "scan" end
        return
    end

    if state.phase == "scan" then
        local ok, err = pcall(scan_step)
        if not ok then
            state.errors = state.errors + 1
            if state.errors <= CFG.err_limit then log("scan error " .. tostring(err)) end
            regions = nil
            return
        end
        if regions == nil then                    -- 一轮扫完
            state.phase = "maintain"
            local first = state.nblocks > 0
            status(first and "OK - table found, patching" or "FAILED - StratagemSettings not found")
            log("scan done blocks=" .. state.nblocks)
        end
        return
    end

    if state.phase == "maintain" then
        if state.frames % CFG.recheck_frames == 0 then
            local n = 0
            for _, b in pairs(state.blocks) do
                local got, alive = maintain_one(b)
                n = n + got
                if not alive then state.blocks[b.b] = nil end
            end
            if n > 0 then status("OK - patch applied") end
            if state.frames % 1800 == 0 then status("OK - patch applied") end
        end
        if state.frames % CFG.full_rescan_frames == 0 then
            log("full rescan"); regions = nil; ri, ro, prev = 1, 0, "" ; pcall(scan_step)
        end
        -- 兜底：区块全没了说明表被换掉了，重新扫
        if state.nblocks == 0 then
            log("no blocks left -> rescan")
            state.blocks = {}; regions = nil; ri, ro, prev = 1, 0, ""
            state.phase = "scan"
        end
        return
    end
end

update = function(...)
    local ok, err = pcall(tick)
    if not ok then
        state.errors = state.errors + 1
        if state.errors <= CFG.err_limit then pcall(log, "tick error " .. tostring(err)) end
    end
    return old(...)
end

log("turret_free_cooldown armed; targets=" .. tostring(state.target_total) .. " type=0x30EB6399")
status("OK - starting")
return state
