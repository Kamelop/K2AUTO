-- K2AUTO Universal Announcement Detector
-- Standalone diagnostic script. It observes client-visible announcement sources
-- and reports the source path + text. It does NOT redeem codes or modify main.lua.
--
-- Run this alongside K2AUTO. When a useful source is identified, its path and
-- payload format can be integrated into the redeemer's normal listener.

if _G.K2UniversalDetector and _G.K2UniversalDetector.Stop then
    pcall(_G.K2UniversalDetector.Stop)
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local LocalPlayer = Players.LocalPlayer

local Detector = {
    Running = true,
    Connections = {},
    WatchedRemotes = {},
    WatchedLabels = {},
    Recent = {},
    RemoteCount = 0,
    GuiCount = 0,
}

_G.K2UniversalDetector = Detector

local MAX_REMOTE_SCAN = 3000
local MAX_TEXT_LENGTH = 500
local DEDUPE_SECONDS = 1.25

local function addConnection(connection)
    if connection then
        table.insert(Detector.Connections, connection)
    end
end

local function cleanText(value)
    if typeof(value) ~= "string" then return nil end
    local text = value:gsub("<[^>]->", ""):gsub("[%c]", " ")
    text = text:gsub("%s+", " ")
    text = text:match("^%s*(.-)%s*$") or ""
    if #text < 3 or #text > MAX_TEXT_LENGTH then return nil end
    return text
end

local function report(source, value)
    if not Detector.Running then return end
    local text = cleanText(value)
    if not text then return end

    local key = source .. "|" .. text
    local now = os.clock()
    if Detector.Recent[key] and now - Detector.Recent[key] < DEDUPE_SECONDS then
        return
    end
    Detector.Recent[key] = now

    local line = string.format("[K2 DETECTOR] SOURCE: %s | TEXT: %s", source, text)
    print(line)

    -- Optional bridge for later integration. Keep it unset during source discovery.
    if type(_G.K2UniversalAnnouncementCallback) == "function" then
        pcall(_G.K2UniversalAnnouncementCallback, text, source)
    end
end

local function scanValue(source, value, depth)
    if depth > 3 then return end
    if typeof(value) == "string" then
        report(source, value)
    elseif typeof(value) == "table" then
        local count = 0
        for key, child in pairs(value) do
            count += 1
            if count > 40 then break end
            scanValue(source .. "." .. tostring(key), child, depth + 1)
        end
    elseif typeof(value) == "Instance" then
        if value:IsA("TextLabel") or value:IsA("TextButton") or value:IsA("TextBox") then
            report(source .. " -> " .. value:GetFullName(), value.Text)
        end
    end
end

local function watchRemote(instance)
    if not Detector.Running or Detector.WatchedRemotes[instance] then return end
    if not (instance:IsA("RemoteEvent") or instance:IsA("UnreliableRemoteEvent")) then return end
    Detector.WatchedRemotes[instance] = true
    Detector.RemoteCount += 1

    addConnection(instance.OnClientEvent:Connect(function(...)
        local args = table.pack(...)
        for i = 1, args.n do
            scanValue(instance:GetFullName() .. " [arg " .. i .. "]", args[i], 0)
        end
    end))
end

local function watchLabel(instance)
    if not Detector.Running or Detector.WatchedLabels[instance] then return end
    if not (instance:IsA("TextLabel") or instance:IsA("TextButton")) then return end
    Detector.WatchedLabels[instance] = true
    Detector.GuiCount += 1

    report("GUI initial " .. instance:GetFullName(), instance.Text)
    addConnection(instance:GetPropertyChangedSignal("Text"):Connect(function()
        report("GUI changed " .. instance:GetFullName(), instance.Text)
    end))
end

-- Observe replicated remotes already present and remotes added later.
for _, instance in ipairs(ReplicatedStorage:GetDescendants()) do
    if Detector.RemoteCount >= MAX_REMOTE_SCAN then break end
    watchRemote(instance)
end

addConnection(ReplicatedStorage.DescendantAdded:Connect(function(instance)
    watchRemote(instance)
end))

-- Observe custom announcement banners and labels in the local player's GUI.
task.spawn(function()
    local playerGui = LocalPlayer:WaitForChild("PlayerGui", 20)
    if not playerGui or not Detector.Running then return end

    for _, instance in ipairs(playerGui:GetDescendants()) do
        watchLabel(instance)
    end

    addConnection(playerGui.DescendantAdded:Connect(function(instance)
        watchLabel(instance)
    end))
end)

-- Roblox's modern chat surface.
pcall(function()
    addConnection(TextChatService.MessageReceived:Connect(function(message)
        local text = message.Text
        local source = "TextChatService.MessageReceived"
        pcall(function()
            if message.TextSource then
                source ..= " userId=" .. tostring(message.TextSource.UserId)
            end
        end)
        report(source, text)
    end))
end)

-- Legacy chat messages, if this game still exposes the old chat hierarchy.
task.spawn(function()
    local events = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
    if not events then
        events = ReplicatedStorage:WaitForChild("DefaultChatSystemChatEvents", 8)
    end
    local onMessage = events and events:FindFirstChild("OnMessageDoneFiltering")
    if onMessage and onMessage:IsA("RemoteEvent") then
        addConnection(onMessage.OnClientEvent:Connect(function(messageData)
            scanValue("DefaultChatSystemChatEvents.OnMessageDoneFiltering", messageData, 0)
        end))
    end
end)

function Detector.Stop()
    if not Detector.Running then return end
    Detector.Running = false
    for _, connection in ipairs(Detector.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Detector.Connections)
    print("[K2 DETECTOR] Stopped.")
end

function Detector.Status()
    print(string.format(
        "[K2 DETECTOR] running=%s | remotes=%d | gui labels=%d",
        tostring(Detector.Running), Detector.RemoteCount, Detector.GuiCount
    ))
end

print("[K2 DETECTOR] Started. Waiting for client-visible announcements...")
print("[K2 DETECTOR] Use _G.K2UniversalDetector.Status() or .Stop()")
