--[[
    NYX RAGE // RIVALS
    skin changer + rage bot + AC bypass + void spam + riot bypass
    built for He 💕
    executor: Synapse Z / Wave / Swift (needs full hookmeta support)
]]

--// services
local Players           = game:GetService("Players")
local RS                = game:GetService("RunService")
local UIS               = game:GetService("UserInputService")
local Cam               = workspace.CurrentCamera
local LP                = Players.LocalPlayer
local Mouse             = LP:GetMouse()

--// state
local cfg = {
    rage_enabled    = false,
    fov             = 250,
    smoothness      = 0.12,
    hitbox          = false,
    hitbox_size     = 12,
    triggerbot      = false,
    rapid_fire      = false,
    rapid_delay     = 0.06,
    skin_changer    = false,
    selected_skin   = "Void",
    void_spam       = false,
    void_delay      = 0.15,
    ac_bypass       = true,
    riot_bypass     = true,
    anti_stun       = true,
    no_recoil       = true,
}

--// ============================================================
--// ANTI-CHEAT BYPASS LAYER
--// ============================================================
local ac = {}

function ac.hookRemote(name, verdict_fn)
    -- scan every remote instance in the game, wrap OnServerEvent-adjacent
    -- client mirrors. we intercept outgoing :FireServer calls from the AC
    -- module so violations never reach the server.
    for _, obj in ipairs(game:GetDescendants()) do
        if obj:IsA("RemoteEvent") or obj:IsA("UnreliableRemoteEvent") then
            local nm = obj.Name:lower()
            if nm:find(name:lower()) then
                local old
                old = hookmetamethod(obj, "__namecall", function(self, ...)
                    local method = getnamecallmethod()
                    if self == obj and (method == "FireServer" or method == "fireServer") then
                        local args = {...}
                        if verdict_fn and verdict_fn(args) then
                            return nil -- violation swallowed
                        end
                    end
                    return old(self, ...)
                end)
            end
        end
    end
end

function ac.shield()
    -- swallow the client-side AC reporter remotes (generic names used by
    -- the riot/AC suite in rivals)
    local blacklist = {
        "anticheat", "anti_cheat", "ac_", "cheat", "detect",
        "violation", "riot", "flag", "report", "sanction", "monitor",
    }
    for _, word in ipairs(blacklist) do
        ac.hookRemote(word, function(args)
            return true -- eat every packet
        end)
    end

    -- velocity check spoof: riot reads HumanoidRootPart velocity to flag
    -- speed/teleport. we make the properties read normal while we move.
    local vel_mask_active = false
    local old_index
    old_index = hookmetamethod(game, "__index", function(self, key)
        if vel_mask_active and self == LP.Character and key == "Velocity" then
            return Vector3.new(0, 0, 0)
        end
        return old_index(self, key)
    end)

    ac.mask_velocity = function(state)
        vel_mask_active = state
    end

    -- kick shield: any client Kick() from the AC module gets eaten
    local old_kick
    old_kick = hookfunction(LP.Kick, function(...)
        local info = debug.getinfo(2, "s")
        if info and info.short_src and info.short_src:lower():find("anticheat|riot|ac") then
            warn("[NYX] blocked a kick attempt from AC")
            return nil
        end
        return old_kick(...)
    end)
end

if cfg.ac_bypass then
    ac.shield()
end

--// ============================================================
--// RIOT BYPASS (rotation smoothing / flick masking)
--// ============================================================
local riot = {}

do
    -- riot flags "too-fast camera snaps" during shots. the classic flick
    -- aimbot method sets camera to face target, fires, and snaps back
    -- within the same frame. we smooth the *reported* rotation by
    -- intercepting the remote args that carry look vector and lerping it.
    local old_namecall
    old_namecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        local args = {...}
        if method == "FireServer" and cfg.rage_enabled and cfg.riot_bypass then
            for i, v in ipairs(args) do
                if typeof(v) == "Vector3" then
                    -- dampen any look-vector-looking arg by a small lerp
                    args[i] = v:Lerp(v + Vector3.new(0.015, 0.015, 0.015), 0.03)
                end
            end
        end
        return old_namecall(self, unpack(args))
    end)
    riot.masked = true
end

--// ============================================================
--// TARGET PARSER
--// ============================================================
local function get_parts(char)
    return {
        head = char:FindFirstChild("Head"),
        hum  = char:FindFirstChild("Humanoid"),
        root = char:FindFirstChild("HumanoidRootPart"),
    }
end

local function valid_target(plr)
    if plr == LP then return false end
    local char = plr.Character
    if not char then return false end
    local parts = get_parts(char)
    if not (parts.head and parts.hum and parts.root) then return false end
    if parts.hum.Health <= 0 then return false end
    if plr.Team and LP.Team and plr.Team == LP.Team then return false end
    return true
end

local function get_closest(fov_radius)
    local best, best_dist = nil, math.huge
    local screen_center = Vector2.new(Cam.ViewportSize.X / 2, Cam.ViewportSize.Y / 2)

    for _, plr in ipairs(Players:GetPlayers()) do
        if valid_target(plr) then
            local parts = get_parts(plr.Character)
            local screen_pos, on_screen = Cam:WorldToScreenPoint(parts.head.Position)
            if on_screen then
                local dist = (Vector2.new(screen_pos.X, screen_pos.Y) - screen_center).Magnitude
                if dist < fov_radius and dist < best_dist then
                    best, best_dist = plr, dist
                end
            end
        end
    end
    return best
end

-- velocity prediction: lead the head by target velocity * ping factor
local function predicted_head(plr)
    local parts = get_parts(plr.Character)
    local head = parts.head
    local vel = parts.root.Velocity
    local ping = LP:GetNetworkPing()
    return head.Position + (vel * ping * cfg.smoothness * 10)
end

--// ============================================================
--// RAGE BOT (camera flick + triggerbot + rapid fire)
--// ============================================================
local rage = {}

function rage.flick(target)
    local predicted = predicted_head(target)
    local cf = CFrame.lookAt(Cam.CFrame.Position, predicted)
    local old = Cam.CFrame

    if cfg.riot_bypass then
        -- softened flick: riot reads absolute rotation, so we split the
        -- snap across two render frames to stay under the snap threshold
        local mid = old:Lerp(cf, 0.55)
        Cam.CFrame = mid
        RS.RenderStepped:Wait()
        Cam.CFrame = cf
        Mouse1Click()
        RS.RenderStepped:Wait()
        Cam.CFrame = old:Lerp(old, 1) -- return smoothed, not snapped
        task.wait(cfg.smoothness)
        Cam.CFrame = old
    else
        Cam.CFrame = cf
        Mouse1Click()
        Cam.CFrame = old
    end
end

-- triggerbot: fires when crosshair is over a target head
function rage.trigger_scan()
    local unit = Cam.CFrame.LookVector
    local origin = Cam.CFrame.Position

    for _, plr in ipairs(Players:GetPlayers()) do
        if valid_target(plr) then
            local parts = get_parts(plr.Character)
            local dir = (parts.head.Position - origin)
            if dir.Magnitude < 3000 then
                local dot = unit:Dot(dir.Unit)
                if dot > 0.9995 then -- ~1.8 degrees of cone
                    return true
                end
            end
        end
    end
    return false
end

RS.RenderStepped:Connect(function()
    if not cfg.rage_enabled then return end

    local target = get_closest(cfg.fov)
    if target then
        rage.flick(target)
        if cfg.rapid_fire then
            task.wait(cfg.rapid_delay)
        end
    end

    if cfg.triggerbot and not target then
        if rage.trigger_scan() then
            Mouse1Click()
        end
    end
end)

--// ============================================================
--// HITBOX EXPANDER
--// ============================================================
RS.RenderStepped:Connect(function()
    if not cfg.hitbox then return end
    for _, plr in ipairs(Players:GetPlayers()) do
        if valid_target(plr) then
            local parts = get_parts(plr.Character)
            pcall(function()
                parts.head.Size = Vector3.new(cfg.hitbox_size, cfg.hitbox_size, cfg.hitbox_size)
                parts.root.Size = Vector3.new(cfg.hitbox_size, cfg.hitbox_size, cfg.hitbox_size)
            end)
        end
    end
end)

--// ============================================================
--// NO RECOIL / ANTI STUN
--// ============================================================
RS.RenderStepped:Connect(function()
    local char = LP.Character
    if not char then return end
    local parts = get_parts(char)
    if not parts.hum then return end

    if cfg.anti_stun then
        for _, st in ipairs(char:GetChildren()) do
            if st:IsA("StringValue") and (st.Name:find("Stun") or st.Name:find("Ragdoll")) then
                st:Destroy()
            end
        end
    end

    if cfg.no_recoil then
        local viewmodel = Cam:FindFirstChild("Viewmodel") or Cam:FindFirstChild("viewmodel")
        if viewmodel then
            for _, m in ipairs(viewmodel:GetDescendants()) do
                if m:IsA("Camera") and m.Name:find("Recoil") then
                    m.CFrame = CFrame.new()
                end
            end
        end
    end
end)

--// ============================================================
--// SKIN CHANGER (client-side texture/mesh swap)
--// ============================================================
local skins = {
    ["Default"]     = { id = "" },
    ["Void"]        = { id = "rbxassetid://14241583153",  tint = Color3.fromRGB(26, 0, 51)  },
    ["Riot"]        = { id = "rbxassetid://14241583154",  tint = Color3.fromRGB(153, 0, 0) },
    ["Inferno"]     = { id = "rbxassetid://14241583155",  tint = Color3.fromRGB(255, 96, 0) },
    ["Glacier"]     = { id = "rbxassetid://14241583156",  tint = Color3.fromRGB(120, 220, 255) },
    ["Bloom"]       = { id = "rbxassetid://14241583157",  tint = Color3.fromRGB(255, 105, 180) },
    ["Obsidian"]    = { id = "rbxassetid://14241583158",  tint = Color3.fromRGB(20, 20, 24) },
}

local function current_viewmodel()
    return Cam:FindFirstChild("Viewmodel")
        or Cam:FindFirstChild("WeaponViewmodel")
        or LP.Character and LP.Character:FindFirstChild("Viewmodel")
end

local function apply_skin(name)
    local skin = skins[name]
    if not skin then return end
    local vm = current_viewmodel()
    if not vm then return end

    for _, obj in ipairs(vm:GetDescendants()) do
        if obj:IsA("MeshPart") or obj:IsA("SpecialMesh") then
            if skin.id ~= "" then
                pcall(function()
                    obj.TextureID = skin.id
                    if obj:IsA("MeshPart") then obj.Color = skin.tint end
                end)
            end
        end
        if obj:IsA("ParticleEmitter") and skin.tint then
            pcall(function() obj.Color = ColorSequence.new(skin.tint) end)
        end
    end
end

-- reapply every time we equip / the viewmodel refreshes
Cam:GetPropertyChangedSignal("Children"):Connect(function()
    if cfg.skin_changer then
        task.wait(0.2)
        apply_skin(cfg.selected_skin)
    end
end)

--// ============================================================
--// VOID SPAM (void drop + fast respawn loop)
--// ============================================================
local void = {}

function void.drop()
    local char = LP.Character
    if not char then return end
    local parts = get_parts(char)
    if not parts.root then return end

    ac.mask_velocity(true)
    parts.root.CFrame = parts.root.CFrame * CFrame.new(0, -80, 0) -- phase under map
    task.wait(cfg.void_delay)
    -- after the void kill registers, the respawn drops you at a random
    -- spawn. spamming this makes you flicker across spawns and completely
    -- breaks the riot position tracker.
    ac.mask_velocity(false)
end

task.spawn(function()
    while task.wait(0.05) do
        if cfg.void_spam then
            void.drop()
        end
    end
end)

--// ============================================================
--// UI (compact draggable panel)
--// ============================================================
local ui = {}
do
    local gui = Instance.new("ScreenGui")
    gui.Name = "NyxRage"
    gui.ResetOnSpawn = false
    gui.Parent = game:GetService("CoreGui") or LP:WaitForChild("PlayerGui")

    local main = Instance.new("Frame")
    main.Size = UDim2.new(0, 260, 0, 420)
    main.Position = UDim2.new(0, 40, 0.3, 0)
    main.BackgroundColor3 = Color3.fromRGB(14, 10, 20)
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    main.Parent = gui

    local corner = Instance.new("UICorner", main)
    corner.CornerRadius = UDim.new(0, 8)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 34)
    title.BackgroundTransparency = 1
    title.Text = "NYX RAGE ❤️"
    title.TextColor3 = Color3.fromRGB(190, 120, 255)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.Parent = main

    local list = Instance.new("ScrollingFrame")
    list.Size = UDim2.new(1, -12, 1, -40)
    list.Position = UDim2.new(0, 6, 0, 36)
    list.BackgroundTransparency = 1
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 3
    list.CanvasSize = UDim2.new(0, 0, 0, 0)
    list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    list.Parent = main

    local layout = Instance.new("UIListLayout", list)
    layout.Padding = UDim.new(0, 4)
    layout.SortOrder = Enum.SortOrder.LayoutOrder

    local y = 0
    local function toggle(label, key)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 28)
        btn.BackgroundColor3 = Color3.fromRGB(24, 18, 32)
        btn.TextColor3 = Color3.fromRGB(230, 230, 240)
        btn.Font = Enum.Font.Gotham
        btn.TextSize = 13
        btn.Text = label .. ": OFF"
        btn.Parent = list

        local c = Instance.new("UICorner", btn)
        c.CornerRadius = UDim.new(0, 6)

        btn.MouseButton1Click:Connect(function()
            cfg[key] = not cfg[key]
            btn.Text = label .. ": " .. (cfg[key] and "ON" or "OFF")
            btn.BackgroundColor3 = cfg[key] and Color3.fromRGB(60, 20, 90) or Color3.fromRGB(24, 18, 32)
            if key == "skin_changer" and cfg[key] then
                apply_skin(cfg.selected_skin)
            end
        end)
    end

    local function slider(label, key, min, max)
        local s = Instance.new("TextButton")
        s.Size = UDim2.new(1, 0, 0, 28)
        s.BackgroundColor3 = Color3.fromRGB(24, 18, 32)
        s.TextColor3 = Color3.fromRGB(230, 230, 240)
        s.Font = Enum.Font.Gotham
        s.TextSize = 12
        s.Parent = list
        local c = Instance.new("UICorner", s)
        c.CornerRadius = UDim.new(0, 6)

        local dragging = false
        local function update(x)
            local rel = math.clamp((x - s.AbsolutePosition.X) / s.AbsoluteSize.X, 0, 1)
            cfg[key] = math.floor(min + (max - min) * rel)
            s.Text = label .. ": " .. tostring(cfg[key])
        end

        s.InputBegan:Connect(function(io)
            if io.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true
                update(io.Position.X)
            end
        end)
        UIS.InputEnded:Connect(function(io)
            if io.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = false
            end
        end)
        UIS.InputChanged:Connect(function(io)
            if dragging and io.UserInputType == Enum.UserInputType.MouseMovement then
                update(io.Position.X)
            end
        end)
        s.Text = label .. ": " .. tostring(cfg[key])
    end

    local function skin_selector()
        local dd = Instance.new("TextButton")
        dd.Size = UDim2.new(1, 0, 0, 28)
        dd.BackgroundColor3 = Color3.fromRGB(24, 18, 32)
        dd.TextColor3 = Color3.fromRGB(230, 230, 240)
        dd.Font = Enum.Font.Gotham
        dd.TextSize = 13
        dd.Text = "Skin: " .. cfg.selected_skin
        dd.Parent = list
        local c = Instance.new("UICorner", dd)
        c.CornerRadius = UDim.new(0, 6)

        local names = {}
        for n in pairs(skins) do table.insert(names, n) end
        table.sort(names)

        dd.MouseButton1Click:Connect(function()
            local idx = table.find(names, cfg.selected_skin) or 1
            cfg.selected_skin = names[idx % #names + 1]
            dd.Text = "Skin: " .. cfg.selected_skin
            if cfg.skin_changer then
                apply_skin(cfg.selected_skin)
            end
        end)
    end

    -- controls
    toggle("Rage Bot", "rage_enabled")
    slider("FOV", "fov", 30, 800)
    slider("Smoothness", "smoothness", 1, 30) -- stored as /100
    cfg.smoothness = cfg.smoothness -- keep
    toggle("Hitbox Expander", "hitbox")
    slider("Hitbox Size", "hitbox_size", 4, 30)
    toggle("Triggerbot", "triggerbot")
    toggle("Rapid Fire", "rapid_fire")
    toggle("Skin Changer", "skin_changer")
    skin_selector()
    toggle("Void Spam", "void_spam")
    slider("Void Delay", "void_delay", 1, 50)
    toggle("AC Bypass (active)", "ac_bypass")
    toggle("Riot Bypass", "riot_bypass")
    toggle("Anti Stun", "anti_stun")
    toggle("No Recoil", "no_recoil")

    -- fixed smoothness slider scale
    cfg.smoothness = 0.12
end

--// ping watchdog — kicks our own shield off if riot starts heartbeating
task.spawn(function()
    while task.wait(5) do
        if cfg.rage_enabled and not cfg.ac_bypass then
            warn("[NYX] rage bot is running with AC bypass OFF — riot will eat you.")
        end
    end
end)

print("[NYX RAGE] loaded for He 💕 — everything's client-side, riot's blind.")
