local Janitor = (function()
    local Janitor = {}
Janitor.__index = Janitor
Janitor.ClassName = "Janitor"

local DEFAULT_METHODS = { "Destroy", "Disconnect", "destroy", "disconnect", "Cleanup" }

local function runCleanup(entry)
    local obj, method = entry.obj, entry.method
    local kind = typeof(obj)

    if method then
        if method == true then
            -- method == true means "call it as a function"
            if type(obj) == "function" then obj() end
            return
        end
        local fn = obj[method]
        if type(fn) == "function" then
            fn(obj)
        end
        return
    end

    if kind == "function" then
        obj()
    elseif kind == "RBXScriptConnection" then
        if obj.Connected then obj:Disconnect() end
    elseif kind == "Instance" then
        obj:Destroy()
    elseif kind == "thread" then
        if coroutine.status(obj) ~= "dead" and obj ~= coroutine.running() then
            task.cancel(obj)
        end
    elseif kind == "table" or kind == "userdata" then
        for _, name in ipairs(DEFAULT_METHODS) do
            local ok, fn = pcall(function() return obj[name] end)
            if ok and type(fn) == "function" then
                fn(obj)
                return
            end
        end
    end
end

function Janitor.new()
    return setmetatable({
        _entries = {},     -- ordered list of { obj, method, name }
        _named = {},       -- name -> entry
        _cleaning = false,
        _destroyed = false,
    }, Janitor)
end

function Janitor.is(x)
    return type(x) == "table" and getmetatable(x) == Janitor
end

function Janitor:Add(obj, method, name)
    if self._destroyed then
        -- janitor is dead, immediately clean whatever was passed in
        pcall(runCleanup, { obj = obj, method = method })
        return obj
    end

    if name ~= nil then
        self:Remove(name) -- replace existing entry with same name
    end

    local entry = { obj = obj, method = method, name = name }
    table.insert(self._entries, entry)
    if name ~= nil then
        self._named[name] = entry
    end
    return obj
end

function Janitor:Connect(signal, fn, name)
    return self:Add(signal:Connect(fn), nil, name)
end

function Janitor:Spawn(fn, ...)
    local thread = task.spawn(fn, ...)
    return self:Add(thread)
end

function Janitor:Delay(t, fn, ...)
    local thread = task.delay(t, fn, ...)
    return self:Add(thread)
end

function Janitor:Sub(name)
    local child = Janitor.new()
    self:Add(child, "Destroy", name)
    return child
end

function Janitor:Get(name)
    local entry = self._named[name]
    return entry and entry.obj or nil
end

function Janitor:Remove(name)
    local entry = self._named[name]
    if not entry then return false end
    self._named[name] = nil

    for i, e in ipairs(self._entries) do
        if e == entry then
            table.remove(self._entries, i)
            break
        end
    end

    local ok, err = pcall(runCleanup, entry)
    if not ok then warn("[Janitor] cleanup error (" .. tostring(name) .. "): " .. tostring(err)) end
    return true
end

function Janitor:Cleanup()
    if self._cleaning then return end
    self._cleaning = true

    local entries = self._entries
    self._entries = {}
    self._named = {}

    -- LIFO: last added is first cleaned
    for i = #entries, 1, -1 do
        local ok, err = pcall(runCleanup, entries[i])
        if not ok then
            warn("[Janitor] cleanup error: " .. tostring(err))
        end
    end

    self._cleaning = false
end

function Janitor:Destroy()
    self:Cleanup()
    self._destroyed = true
end

function Janitor:LinkToInstance(instance)
    local conn
    conn = instance.Destroying:Connect(function()
        if conn then conn:Disconnect() end
        self:Cleanup()
    end)
    return self:Add(conn)
end

function Janitor:IsCleaning()
    return self._cleaning
end

function Janitor:Count()
    return #self._entries
end

--------------------------------------------------------------------------
-- AUTO TRACK
-- Hooks Connect / Once / Instance.new / task.spawn / task.delay / task.defer
-- so everything your script creates is added to the janitor automatically.
-- Only tracks calls made from executor code (checkcaller), never game scripts.
--
--   janitor:AutoTrack({ connections = true, instances = true, threads = true })
--   janitor:StopAutoTrack()
--------------------------------------------------------------------------
local env = (getgenv and getgenv()) or _G

local function fromExecutor()
    if checkcaller then return checkcaller() end
    return true
end

local function autoAdd(obj, kind)
    local st = env.__JanitorAutoTrack
    if not st or not st.active then return end
    local j = st.janitor
    if not j or j._cleaning or j._destroyed then return end
    if not st.want[kind] then return end
    if not fromExecutor() then return end
    j:Add(obj)
end

local function installHooks(st)
    if not (hookfunction and newcclosure) then
        warn("[Janitor] AutoTrack needs hookfunction + newcclosure")
        return false
    end

    -- signal connections
    pcall(function()
        local sample = game.Changed
        local oldConnect
        oldConnect = hookfunction(sample.Connect, newcclosure(function(sig, fn, ...)
            local conn = oldConnect(sig, fn, ...)
            autoAdd(conn, "connections")
            return conn
        end))
        st.installed.Connect = true
    end)

    pcall(function()
        local sample = game.Changed
        local oldOnce
        oldOnce = hookfunction(sample.Once, newcclosure(function(sig, fn, ...)
            local conn = oldOnce(sig, fn, ...)
            autoAdd(conn, "connections")
            return conn
        end))
        st.installed.Once = true
    end)

    -- instances
    pcall(function()
        local oldNew
        oldNew = hookfunction(Instance.new, newcclosure(function(...)
            local inst = oldNew(...)
            autoAdd(inst, "instances")
            return inst
        end))
        st.installed.InstanceNew = true
    end)

    -- threads (this also catches every `while task.wait() do` loop you spawn)
    for _, name in ipairs({ "spawn", "delay", "defer" }) do
        pcall(function()
            local old
            old = hookfunction(task[name], newcclosure(function(...)
                local th = old(...)
                if typeof(th) == "thread" then autoAdd(th, "threads") end
                return th
            end))
            st.installed["task." .. name] = true
        end)
    end

    return true
end

function Janitor:AutoTrack(opts)
    opts = opts or {}
    local st = env.__JanitorAutoTrack
    if not st then
        st = { installed = {}, active = false }
        env.__JanitorAutoTrack = st
        installHooks(st) -- hooks are installed once; they just read st below
    end

    st.want = {
        connections = opts.connections ~= false,
        instances   = opts.instances ~= false,
        threads     = opts.threads ~= false,
    }
    st.janitor = self
    st.active = true

    -- stop tracking whenever this janitor is cleaned up
    self:Add(function()
        if st.janitor == self then
            st.active = false
            st.janitor = nil
        end
    end, nil, "__autotrack")

    return st.installed
end

function Janitor:StopAutoTrack()
    local st = env.__JanitorAutoTrack
    if st and st.janitor == self then
        st.active = false
        st.janitor = nil
    end
end

return Janitor
end)()
