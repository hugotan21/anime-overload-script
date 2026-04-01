---------------------------------------------------------------------
-- 🧠 SERVICES
---------------------------------------------------------------------
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local placedTowers = workspace:WaitForChild("placedTowers")

local syncNet = require(game.ReplicatedStorage.gameClient.net.sync)
local towersNet = require(game.ReplicatedStorage.gameClient.net.towers)

---------------------------------------------------------------------
-- AUTO AFK
---------------------------------------------------------------------
local VU = game:GetService("VirtualUser")
game:GetService("Players").LocalPlayer.Idled:Connect(function()
    VU:CaptureController()
    VU:ClickButton2(Vector2.new(0,0))
end)
print("Anti-AFK is active.")

---------------------------------------------------------------------
-- CARD GUI PATH
---------------------------------------------------------------------
local cardGuiFolder = game:GetService("Players")
    .LocalPlayer
    .PlayerGui
    :WaitForChild("cardModifiers")
    :WaitForChild("container")
    :WaitForChild("content")
    :WaitForChild("cards")
---------------------------------------------------------------------
-- 🧠 STATE
---------------------------------------------------------------------
local recording = false
local autofarm = false
local running = false
local autoPickCards = false
local stopSignal = false
local lastStatus = false

---------------------------------------------------------------------
-- 💾 RECORDING SLOT STATE
---------------------------------------------------------------------
local RECORDS_FOLDER = "tower_records"
if not isfolder(RECORDS_FOLDER) then
    makefolder(RECORDS_FOLDER)
end

local activeRecordName = "default"
local activeRecordFile = RECORDS_FOLDER .. "/default.json"
if not isfile(activeRecordFile) then
    writefile(activeRecordFile, "[]")
end
local selectedRecordName = "default"

---------------------------------------------------------------------
-- 🧼 YOUR PRETTY JSON (UNCHANGED)
---------------------------------------------------------------------
local function prettyJSON(data)
    local raw = HttpService:JSONEncode(data)

    local indent = 0
    local pretty = ""

    for i = 1, #raw do
        local char = raw:sub(i, i)

        if char == "{" or char == "[" then
            indent += 1
            pretty ..= char .. "\n" .. string.rep("  ", indent)

        elseif char == "}" or char == "]" then
            indent -= 1
            pretty ..= "\n" .. string.rep("  ", indent) .. char

        elseif char == "," then
            pretty ..= char .. "\n" .. string.rep("  ", indent)

        else
            pretty ..= char
        end
    end

    return pretty
end

---------------------------------------------------------------------
-- 📍 HELPERS (UNCHANGED)
---------------------------------------------------------------------
local function getTowerName(tower)
    local hrp = tower:FindFirstChild("HumanoidRootPart")
    if not hrp then return "Unknown" end

    local info = hrp:FindFirstChild("infoIndicator")
    if not info then return "Unknown" end

    local towerName = info:FindFirstChild("towerName")
    if not towerName then return "Unknown" end

    return towerName.Text
end

local function isMine(tower)
    local hrp = tower:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end

    local info = hrp:FindFirstChild("infoIndicator")
    if not info then return false end

    local ownerName = info:FindFirstChild("ownerName")
    if not ownerName then return false end

    return ownerName.Text == player.Name
end

---------------------------------------------------------------------
-- 💾 RECORDING SLOT HELPERS
---------------------------------------------------------------------
local function sanitizeRecordName(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[<>:\"/\\|%?%*]", "_")
    if name == "" then
        name = "default"
    end
    return name
end

local function getRecordFile(name)
    name = sanitizeRecordName(name)
    return RECORDS_FOLDER .. "/" .. name .. ".json", name
end

local function setActiveRecord(name)
    local file, cleanName = getRecordFile(name)
    activeRecordName = cleanName
    activeRecordFile = file
    selectedRecordName = cleanName
end

local function listRecordNames()
    local results = {}

    if listfiles then
        for _, path in ipairs(listfiles(RECORDS_FOLDER)) do
            local fileName = path:match("([^/\\]+)%.json$")
            if fileName then
                table.insert(results, fileName)
            end
        end
    end

    table.sort(results, function(a, b)
        return a:lower() < b:lower()
    end)

    return results
end

local function readActiveRecordData()
    if not isfile(activeRecordFile) then
        return {}
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(activeRecordFile))
    end)

    if ok and type(data) == "table" then
        return data
    end

    return {}
end

local function saveTableToActiveRecord(data)
    writefile(activeRecordFile, prettyJSON(data))
end

---------------------------------------------------------------------
-- 📦 RECORDER (UNCHANGED)
---------------------------------------------------------------------
local saveData = {}
local lastUnitId = nil

local old
old = hookfunction(syncNet.clientTowerPlacement.call, function(...)
    local args = {...}
    lastUnitId = args[1]
    return old(...)
end)

placedTowers.ChildAdded:Connect(function(tower)
    if not recording then return end

    task.wait(0.2)

    if isMine(tower) then
        local hrp = tower:FindFirstChild("HumanoidRootPart")
        if not hrp then return end

        local pos = hrp.Position
        local name = getTowerName(tower)

        local data = {
            name = name,
            unitId = lastUnitId,
            x = math.floor(pos.X * 100) / 100,
            y = math.floor(pos.Y * 100) / 100,
            z = math.floor(pos.Z * 100) / 100,
            priority = 1
        }

        table.insert(saveData, data)
        writefile(activeRecordFile, prettyJSON(saveData))
    end
end)

---------------------------------------------------------------------
-- 🚀 AUTOPLACE (UNCHANGED + STOP SUPPORT)
---------------------------------------------------------------------
local function runAutoplace()
    local data = readActiveRecordData()

    local function isTowerPlaced(name, pos)
        for _, tower in pairs(workspace.placedTowers:GetChildren()) do
            local hrp = tower:FindFirstChild("HumanoidRootPart")
            if hrp then
                if (hrp.Position - pos).Magnitude < 3 then
                    if getTowerName(tower) == name then
                        return true
                    end
                end
            end
        end
        return false
    end

    for _, tower in ipairs(data) do
        if stopSignal then return end

        local pos = Vector3.new(tower.x, tower.y, tower.z)

        repeat
            if stopSignal then return end
            task.wait(0.05)

            pcall(function()
                syncNet.clientTowerPlacement.call(
                    tower.unitId,
                    CFrame.new(pos)
                )
            end)

        until isTowerPlaced(tower.name, pos)
    end
end

---------------------------------------------------------------------
-- 🔼 AUTOUPGRADE (UNCHANGED + STOP SUPPORT)
---------------------------------------------------------------------
local function runAutoupgrade()
    local data = readActiveRecordData()
    local hitboxes = workspace:WaitForChild("hitboxes")
    local upgradeText = player.PlayerGui.upgradeGui.mainFrame.content.upgrade.upgrades

    repeat task.wait() until #placedTowers:GetChildren() >= #data

    local recordToTower = {}
    local towerToHitbox = {}
    local maxed = {}

    local priorities = {}
    for _, record in ipairs(data) do
        priorities[record.priority] = priorities[record.priority] or {}
        table.insert(priorities[record.priority], record)
    end

    local sortedPriorities = {}
    for p in pairs(priorities) do table.insert(sortedPriorities, p) end
    table.sort(sortedPriorities)

    for _, record in ipairs(data) do
        local targetPos = Vector3.new(record.x, record.y, record.z)

        for _, tower in pairs(placedTowers:GetChildren()) do
            if isMine(tower) and tower:FindFirstChild("HumanoidRootPart") then
                if (tower.HumanoidRootPart.Position - targetPos).Magnitude < 3 then
                    recordToTower[record] = tower
                    break
                end
            end
        end
    end

    for _, tower in pairs(placedTowers:GetChildren()) do
        if tower:FindFirstChild("HumanoidRootPart") then
            for _, hitbox in pairs(hitboxes:GetChildren()) do
                if hitbox:IsA("BasePart") then
                    if (hitbox.Position - tower.HumanoidRootPart.Position).Magnitude < 3 then
                        towerToHitbox[tower] = hitbox
                        break
                    end
                end
            end
        end
    end

    while true do
        if stopSignal then return end
        task.wait(0.3)

        local allDone = true

        for _, priority in ipairs(sortedPriorities) do
            local group = priorities[priority]
            local groupDone = true

            for _, record in ipairs(group) do
                if stopSignal then return end
                if maxed[record] then continue end

                local tower = recordToTower[record]
                if not tower then continue end

                local hitbox = towerToHitbox[tower]
                if not hitbox then continue end

                local cd = hitbox:FindFirstChildOfClass("ClickDetector")
                if not cd then continue end

                fireclickdetector(cd)
                task.wait(0.1)

                if upgradeText.Text == "MAX UPGRADE" then
                    maxed[record] = true
                    continue
                end

                groupDone = false
                allDone = false

                pcall(function()
                    towersNet.upgradeUnit.call(tower.Name)
                end)

                task.wait(0.1)
            end

            if not groupDone then break end
        end

        if allDone then break end
    end
end

---------------------------------------------------------------------
-- 🔁 AUTOFARM
---------------------------------------------------------------------
---------------------------------------------------------------------
-- 🔁 AUTOFARM (WITH AUTO START)
---------------------------------------------------------------------
local function runAutofarm()
    stopSignal = true
    task.wait(0.2)
    stopSignal = false

    running = true

    task.spawn(function()
        -----------------------------------------------------------------
        -- 🟢 START GAME (NEW)
        -----------------------------------------------------------------
        pcall(function()
            local votingNet = require(game:GetService("ReplicatedStorage").gameClient.net.votingNet)
            votingNet.startMatch.fire()
        end)

        -- small delay so game actually starts before placing
        task.wait(1)

        -----------------------------------------------------------------
        -- 🚀 YOUR ORIGINAL FLOW
        -----------------------------------------------------------------
        runAutoplace()
        if stopSignal then running = false return end

        runAutoupgrade()
        running = false
    end)
end

---------------------------------------------------------------------
-- 🧠 STATUS GUI DETECTION
---------------------------------------------------------------------
task.spawn(function()
    while true do
        task.wait(0.5)

        local statusGui = player.PlayerGui:FindFirstChild("statusGui")
        if not statusGui then continue end

        if statusGui.Enabled and not lastStatus then
            lastStatus = true
        end

        if not statusGui.Enabled and lastStatus then
            lastStatus = false

            if autofarm then
                runAutofarm()
            end
        end
    end
end)

---------------------------------------------------------------------
-- 🖥️ UI
---------------------------------------------------------------------
local gui = Instance.new("ScreenGui", player.PlayerGui)

local frame = Instance.new("Frame", gui)
frame.Size = UDim2.new(0, 200, 0, 290)
frame.Position = UDim2.new(0.1, 0, 0.3, 0)
frame.BackgroundColor3 = Color3.fromRGB(25,25,25)
frame.Active = true
frame.Draggable = true

local openRecordsBtn = Instance.new("TextButton", frame)
openRecordsBtn.Size = UDim2.new(1, -10, 0, 30)
openRecordsBtn.Position = UDim2.new(0, 5, 0, 5)
openRecordsBtn.Text = "Open Recordings"

local currentConfigLabel = Instance.new("TextLabel", frame)
currentConfigLabel.Size = UDim2.new(1, -10, 0, 20)
currentConfigLabel.Position = UDim2.new(0, 5, 0, 40)
currentConfigLabel.BackgroundTransparency = 1
currentConfigLabel.TextColor3 = Color3.fromRGB(255,255,255)
currentConfigLabel.TextXAlignment = Enum.TextXAlignment.Left
currentConfigLabel.Text = "Config: " .. activeRecordName

local recordBtn = Instance.new("TextButton", frame)
recordBtn.Size = UDim2.new(1, -10, 0, 40)
recordBtn.Position = UDim2.new(0, 5, 0, 65)
recordBtn.Text = "Recording: OFF"

local autoBtn = Instance.new("TextButton", frame)
autoBtn.Size = UDim2.new(1, -10, 0, 40)
autoBtn.Position = UDim2.new(0, 5, 0, 115)
autoBtn.Text = "Autofarm: OFF"

local cardToggleBtn = Instance.new("TextButton", frame)
cardToggleBtn.Size = UDim2.new(1, -10, 0, 30)
cardToggleBtn.Position = UDim2.new(0, 5, 0, 165)
cardToggleBtn.Text = "Auto Pick Cards: OFF"

---------------------------------------------------------------------
-- 💾 RECORDINGS WINDOW
---------------------------------------------------------------------
local recordsFrame = Instance.new("Frame", gui)
recordsFrame.Size = UDim2.new(0, 260, 0, 360)
recordsFrame.Position = UDim2.new(0.32, 0, 0.3, 0)
recordsFrame.BackgroundColor3 = Color3.fromRGB(30,30,30)
recordsFrame.Visible = false
recordsFrame.Active = true
recordsFrame.Draggable = true

local activeSlotLabel = Instance.new("TextLabel", recordsFrame)
activeSlotLabel.Size = UDim2.new(1, -10, 0, 20)
activeSlotLabel.Position = UDim2.new(0, 5, 0, 5)
activeSlotLabel.BackgroundTransparency = 1
activeSlotLabel.TextColor3 = Color3.fromRGB(0,255,150)
activeSlotLabel.TextXAlignment = Enum.TextXAlignment.Left
activeSlotLabel.Text = "Active: " .. activeRecordName

local slotNameBox = Instance.new("TextBox", recordsFrame)
slotNameBox.Size = UDim2.new(1, -10, 0, 30)
slotNameBox.Position = UDim2.new(0, 5, 0, 30)
slotNameBox.Text = activeRecordName
slotNameBox.PlaceholderText = "Enter slot name"
slotNameBox.ClearTextOnFocus = false
slotNameBox.BackgroundColor3 = Color3.fromRGB(45,45,45)
slotNameBox.TextColor3 = Color3.fromRGB(255,255,255)

local loadSlotBtn = Instance.new("TextButton", recordsFrame)
loadSlotBtn.Size = UDim2.new(1, -10, 0, 30)
loadSlotBtn.Position = UDim2.new(0, 5, 0, 70)
loadSlotBtn.Text = "Load"

local refreshSlotBtn = Instance.new("TextButton", recordsFrame)
refreshSlotBtn.Size = UDim2.new(1, -10, 0, 30)
refreshSlotBtn.Position = UDim2.new(0, 5, 0, 105)
refreshSlotBtn.Text = "Refresh"

local newRecordingBtn = Instance.new("TextButton", recordsFrame)
newRecordingBtn.Size = UDim2.new(1, -10, 0, 30)
newRecordingBtn.Position = UDim2.new(0, 5, 0, 140)
newRecordingBtn.Text = "New Recording"

local renameBtn = Instance.new("TextButton", recordsFrame)
renameBtn.Size = UDim2.new(1, -10, 0, 30)
renameBtn.Position = UDim2.new(0, 5, 0, 175)
renameBtn.Text = "Rename Selected"

local deleteBtn = Instance.new("TextButton", recordsFrame)
deleteBtn.Size = UDim2.new(1, -10, 0, 30)
deleteBtn.Position = UDim2.new(0, 5, 0, 210)
deleteBtn.Text = "Delete Selected"

local slotList = Instance.new("ScrollingFrame", recordsFrame)
slotList.Size = UDim2.new(1, -10, 1, -250)
slotList.Position = UDim2.new(0, 5, 0, 245)
slotList.BackgroundColor3 = Color3.fromRGB(40,40,40)
slotList.CanvasSize = UDim2.new(0,0,0,0)
slotList.ScrollBarThickness = 6

local layout = Instance.new("UIListLayout")
layout.Parent = slotList
layout.Padding = UDim.new(0, 5)

layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    slotList.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 10)
end)

local function updateConfigLabels()
    currentConfigLabel.Text = "Config: " .. activeRecordName
    activeSlotLabel.Text = "Active: " .. activeRecordName
end

local function refreshSlotList()

    local names = listRecordNames()
    
    print("FILES FOUND:", #names)
    for _, v in ipairs(names) do
        print(" -", v)
    end
    -- clear old buttons
    for _, child in ipairs(slotList:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    

    for _, name in ipairs(names) do

        local btn = Instance.new("TextButton")
        btn.Parent = slotList
        btn.Size = UDim2.new(1, -10, 0, 30)
        btn.Text = name
        btn.TextColor3 = Color3.fromRGB(255,255,255)
        btn.BackgroundColor3 = Color3.fromRGB(55,55,55)

        -- highlight active slot
        if name == activeRecordName then
            btn.BackgroundColor3 = Color3.fromRGB(60,120,60)
        end

        -- CLICK HANDLER
        btn.MouseButton1Click:Connect(function()

            selectedRecordName = name
            slotNameBox.Text = name

            -- update highlight
            for _, b in ipairs(slotList:GetChildren()) do
                if b:IsA("TextButton") then
                    b.BackgroundColor3 = Color3.fromRGB(55,55,55)
                end
            end

            btn.BackgroundColor3 = Color3.fromRGB(120,120,60)

        end)
    end

    updateConfigLabels()
end
---------------------------------------------------------------------
-- 🔘 BUTTONS
---------------------------------------------------------------------

openRecordsBtn.MouseButton1Click:Connect(function()
    recordsFrame.Visible = not recordsFrame.Visible

    if recordsFrame.Visible then
        refreshSlotList()
    end
end)

recordBtn.MouseButton1Click:Connect(function()
    recording = not recording
    recordBtn.Text = "Recording: " .. (recording and "ON" or "OFF")

    if recording then
        saveData = {}
        writefile(activeRecordFile, prettyJSON(saveData))
        updateConfigLabels()
    end
end)

loadSlotBtn.MouseButton1Click:Connect(function()

    if not selectedRecordName then
        warn("No recording selected")
        return
    end

    setActiveRecord(selectedRecordName)
    saveData = readActiveRecordData()

    slotNameBox.Text = selectedRecordName

    updateConfigLabels()
    refreshSlotList()

end)

refreshSlotBtn.MouseButton1Click:Connect(function()
    refreshSlotList()
end)

newRecordingBtn.MouseButton1Click:Connect(function()
    local base = "recording"
    local i = 1
    local name = base
    local file = RECORDS_FOLDER .. "/" .. name .. ".json"

    while isfile(file) do
        name = base .. "_" .. i
        file = RECORDS_FOLDER .. "/" .. name .. ".json"
        i += 1
    end

    writefile(file, "[]")
    setActiveRecord(name)
    saveData = {}
    slotNameBox.Text = name
    updateConfigLabels()
    refreshSlotList()
end)

renameBtn.MouseButton1Click:Connect(function()
    if not selectedRecordName then
        warn("Select a recording first")
        return
    end

    local oldFile, oldName = getRecordFile(selectedRecordName)
    local newFile, newName = getRecordFile(slotNameBox.Text)

    if oldName == newName then
        return
    end

    if not isfile(oldFile) then
        warn("Selected recording does not exist")
        return
    end

    if isfile(newFile) then
        warn("A recording with that name already exists")
        return
    end

    writefile(newFile, readfile(oldFile))
    delfile(oldFile)

    if activeRecordName == oldName then
        setActiveRecord(newName)
        saveData = readActiveRecordData()
    else
        selectedRecordName = newName
    end

    slotNameBox.Text = newName
    updateConfigLabels()
    refreshSlotList()
end)

deleteBtn.MouseButton1Click:Connect(function()
    if not selectedRecordName then
        warn("Select a recording first")
        return
    end

    local file, cleanName = getRecordFile(selectedRecordName)

    if not isfile(file) then
        warn("Recording does not exist")
        return
    end

    delfile(file)

    if activeRecordName == cleanName then
        setActiveRecord("default")
        if not isfile(activeRecordFile) then
            writefile(activeRecordFile, "[]")
        end
        saveData = readActiveRecordData()
        slotNameBox.Text = activeRecordName
    else
        slotNameBox.Text = activeRecordName
        selectedRecordName = activeRecordName
    end

    updateConfigLabels()
    refreshSlotList()
end)

autoBtn.MouseButton1Click:Connect(function()
    autofarm = not autofarm

    if autofarm then
        autoBtn.Text = "Autofarm: ON"
        runAutofarm()
    else
        autoBtn.Text = "Autofarm: OFF"
        stopSignal = true
        print("🛑 Stopped")
    end
end)

cardToggleBtn.MouseButton1Click:Connect(function()

    autoPickCards = not autoPickCards

    if autoPickCards then
        cardToggleBtn.Text = "Auto Pick Cards: ON"
    else
        cardToggleBtn.Text = "Auto Pick Cards: OFF"
    end

end)



-------------------------------------
-- 🔘 edit proririty
---------------------------------------------------------------------
---------------------------------------------------------------------
-- 🛠️ PRIORITY EDITOR (ADD-ON ONLY, DOES NOT MODIFY YOUR SCRIPT)
---------------------------------------------------------------------

-- Button inside your existing frame
local editBtn = Instance.new("TextButton")
editBtn.Parent = frame
editBtn.Size = UDim2.new(1, -10, 0, 30)
editBtn.Position = UDim2.new(0, 5, 1, -35)
editBtn.Text = "Edit Priorities"

-- Editor window
local editor = Instance.new("Frame")
editor.Parent = gui
editor.Size = UDim2.new(0, 260, 0, 300)
editor.Position = UDim2.new(0.3, 0, 0.3, 0)
editor.BackgroundColor3 = Color3.fromRGB(30,30,30)
editor.Visible = false
editor.Active = true
editor.Draggable = true

local scroll = Instance.new("ScrollingFrame")
scroll.Parent = editor
scroll.Size = UDim2.new(1, -10, 1, -40)
scroll.Position = UDim2.new(0, 5, 0, 5)
scroll.CanvasSize = UDim2.new(0,0,0,0)
scroll.BackgroundTransparency = 1

local saveBtn = Instance.new("TextButton")
saveBtn.Parent = editor
saveBtn.Size = UDim2.new(1, -10, 0, 30)
saveBtn.Position = UDim2.new(0, 5, 1, -35)
saveBtn.Text = "SAVE"

local loadedData = {}

local function loadEditor()
    for _, v in pairs(scroll:GetChildren()) do
        if v:IsA("Frame") then v:Destroy() end
    end

    loadedData = readActiveRecordData()

    local y = 0
    for _, tower in ipairs(loadedData) do
        local row = Instance.new("Frame")
        row.Parent = scroll
        row.Size = UDim2.new(1, 0, 0, 40)
        row.Position = UDim2.new(0, 0, 0, y)
        row.BackgroundTransparency = 1

        local name = Instance.new("TextLabel")
        name.Parent = row
        name.Size = UDim2.new(0.5, 0, 1, 0)
        name.Text = tower.name
        name.BackgroundTransparency = 1
        name.TextXAlignment = Enum.TextXAlignment.Left
        name.TextColor3 = Color3.fromRGB(255, 255, 255)

        local prio = Instance.new("TextLabel")
        prio.Parent = row
        prio.Size = UDim2.new(0.2, 0, 1, 0)
        prio.Position = UDim2.new(0.5, 0, 0, 0)
        prio.Text = tostring(tower.priority)
        prio.BackgroundTransparency = 1
        prio.TextColor3 = Color3.fromRGB(255, 255, 255)

        local plus = Instance.new("TextButton")
        plus.Parent = row
        plus.Size = UDim2.new(0.15, 0, 1, 0)
        plus.Position = UDim2.new(0.7, 0, 0, 0)
        plus.Text = "+"

        local minus = Instance.new("TextButton")
        minus.Parent = row
        minus.Size = UDim2.new(0.15, 0, 1, 0)
        minus.Position = UDim2.new(0.85, 0, 0, 0)
        minus.Text = "-"

        plus.MouseButton1Click:Connect(function()
            tower.priority += 1
            prio.Text = tostring(tower.priority)
        end)

        minus.MouseButton1Click:Connect(function()
            tower.priority = math.max(1, tower.priority - 1)
            prio.Text = tostring(tower.priority)
        end)

        y += 40
    end

    scroll.CanvasSize = UDim2.new(0,0,0,y)
end

editBtn.MouseButton1Click:Connect(function()
    editor.Visible = not editor.Visible
    if editor.Visible then
        loadEditor()
    end
end)

saveBtn.MouseButton1Click:Connect(function()
    saveTableToActiveRecord(loadedData)
    print("💾 Priorities saved to:", activeRecordName)
end)

local VirtualInputManager = game:GetService("VirtualInputManager")

local function press(key)
VirtualInputManager:SendKeyEvent(true, key, false, game)
task.wait(0.1)
VirtualInputManager:SendKeyEvent(false, key, false, game)
end

---------------------------------------------------------------------
-- 🃏 CARD PRIORITY EDITOR (ATTACHED TO SAME GUI)
---------------------------------------------------------------------

local CONTRACT_FILE = "priority_contracts.json"
local NORMAL_FILE = "priority_normal.json"

---------------------------------------------------------------------
-- BUTTON INSIDE YOUR EXISTING FRAME
---------------------------------------------------------------------

local cardBtn = Instance.new("TextButton")
cardBtn.Parent = frame
cardBtn.Size = UDim2.new(1, -10, 0, 30)
cardBtn.Position = UDim2.new(0, 5, 1, -65)
cardBtn.Text = "Edit Card Priorities"

---------------------------------------------------------------------
-- GET CARDS
---------------------------------------------------------------------

local contractsFolder = game:GetService("ReplicatedStorage").gameShared.config.contracts
local contractCards = {}

for _, module in pairs(contractsFolder:GetDescendants()) do
    if module:IsA("ModuleScript") then
        table.insert(contractCards, {name = module.Name, priority = 1})
    end
end

local cardsFolder = game:GetService("ReplicatedStorage").gameShared.config.cards.util.cards
local normalCards = {}

for _, module in pairs(cardsFolder:GetChildren()) do
    if module:IsA("ModuleScript") then
        table.insert(normalCards, {name = module.Name, priority = 1})
    end
end

---------------------------------------------------------------------
-- LOAD SAVED
---------------------------------------------------------------------

if isfile(CONTRACT_FILE) then
    local data = HttpService:JSONDecode(readfile(CONTRACT_FILE))
    for _, card in ipairs(contractCards) do
        if data[card.name] then
            card.priority = data[card.name]
        end
    end
end

if isfile(NORMAL_FILE) then
    local data = HttpService:JSONDecode(readfile(NORMAL_FILE))
    for _, card in ipairs(normalCards) do
        if data[card.name] then
            card.priority = data[card.name]
        end
    end
end

---------------------------------------------------------------------
-- GLOBAL TABLES
---------------------------------------------------------------------

getgenv().priorityContracts = {}
getgenv().priorityNormal = {}

for _, v in ipairs(contractCards) do
    getgenv().priorityContracts[v.name] = v.priority
end

for _, v in ipairs(normalCards) do
    getgenv().priorityNormal[v.name] = v.priority
end

---------------------------------------------------------------------
-- EDITOR WINDOW
---------------------------------------------------------------------

local cardEditor = Instance.new("Frame")
cardEditor.Parent = gui
cardEditor.Size = UDim2.new(0, 520, 0, 350)
cardEditor.Position = UDim2.new(0.3, 0, 0.3, 0)
cardEditor.BackgroundColor3 = Color3.fromRGB(30,30,30)
cardEditor.Visible = false
cardEditor.Active = true
cardEditor.Draggable = true

local title = Instance.new("TextLabel")
title.Parent = cardEditor
title.Size = UDim2.new(1, 0, 0, 30)
title.Text = "Card Priority Editor"
title.BackgroundTransparency = 1
title.TextColor3 = Color3.fromRGB(255,255,255)

local contractScroll = Instance.new("ScrollingFrame")
contractScroll.Parent = cardEditor
contractScroll.Size = UDim2.new(0.48, 0, 1, -70)
contractScroll.Position = UDim2.new(0.01, 0, 0, 30)
contractScroll.BackgroundTransparency = 1

local normalScroll = Instance.new("ScrollingFrame")
normalScroll.Parent = cardEditor
normalScroll.Size = UDim2.new(0.48, 0, 1, -70)
normalScroll.Position = UDim2.new(0.51, 0, 0, 30)
normalScroll.BackgroundTransparency = 1

---------------------------------------------------------------------
-- POPULATE
---------------------------------------------------------------------

local function makeHeader(parent, text, color)

    local label = Instance.new("TextLabel")
    label.Parent = parent
    label.Size = UDim2.new(1, 0, 0, 20)
    label.Text = text
    label.BackgroundTransparency = 1
    label.TextColor3 = color

end

local function populate(scroll, data)

    local y = 25

    for _, card in ipairs(data) do

        local row = Instance.new("Frame")
        row.Parent = scroll
        row.Size = UDim2.new(1, 0, 0, 35)
        row.Position = UDim2.new(0, 0, 0, y)
        row.BackgroundTransparency = 1

        local name = Instance.new("TextLabel")
        name.Parent = row
        name.Size = UDim2.new(0.6, 0, 1, 0)
        name.Text = card.name
        name.BackgroundTransparency = 1
        name.TextXAlignment = Enum.TextXAlignment.Left
        name.TextColor3 = Color3.fromRGB(255,255,255)

        local input = Instance.new("TextBox")
        input.Parent = row
        input.Size = UDim2.new(0.3, 0, 0.8, 0)
        input.Position = UDim2.new(0.65, 0, 0.1, 0)
        input.Text = tostring(card.priority)
        input.BackgroundColor3 = Color3.fromRGB(50,50,50)
        input.TextColor3 = Color3.fromRGB(255,255,255)

        input.FocusLost:Connect(function(enterPressed)

            if enterPressed then
                local num = tonumber(input.Text)

                if num then
                    card.priority = num
                else
                    input.Text = tostring(card.priority)
                end

            end

        end)

        y += 35

    end

    scroll.CanvasSize = UDim2.new(0,0,0,y)

end

---------------------------------------------------------------------
-- SAVE
---------------------------------------------------------------------

local saveBtnCards = Instance.new("TextButton")
saveBtnCards.Parent = cardEditor
saveBtnCards.Size = UDim2.new(1, -10, 0, 30)
saveBtnCards.Position = UDim2.new(0, 5, 1, -35)
saveBtnCards.Text = "SAVE"

saveBtnCards.MouseButton1Click:Connect(function()

    local contractSave = {}
    local normalSave = {}

    table.clear(getgenv().priorityContracts)
    table.clear(getgenv().priorityNormal)

    for _, v in ipairs(contractCards) do
        contractSave[v.name] = v.priority
        getgenv().priorityContracts[v.name] = v.priority
    end

    for _, v in ipairs(normalCards) do
        normalSave[v.name] = v.priority
        getgenv().priorityNormal[v.name] = v.priority
    end

    writefile(CONTRACT_FILE, HttpService:JSONEncode(contractSave))
    writefile(NORMAL_FILE, HttpService:JSONEncode(normalSave))

    print("💾 Card priorities saved")

end)

---------------------------------------------------------------------
-- TOGGLE
---------------------------------------------------------------------

cardBtn.MouseButton1Click:Connect(function()

    cardEditor.Visible = not cardEditor.Visible

    if cardEditor.Visible then

        contractScroll:ClearAllChildren()
        normalScroll:ClearAllChildren()

        makeHeader(contractScroll,"Contracts Card Priority (Press Enter to Confirm)",Color3.fromRGB(255,100,100))
        makeHeader(normalScroll,"Normal Card Priority",Color3.fromRGB(100,150,255))

        populate(contractScroll,contractCards)
        populate(normalScroll,normalCards)

    end

end)

---------------------------------------------------------------------
-- WAIT FOR CARD GUI TO LOAD
---------------------------------------------------------------------
local function waitForCards()

    repeat
        task.wait()

        local count = 0

        for _, v in pairs(cardGuiFolder:GetChildren()) do
            if not v:IsA("UIListLayout") then
                count += 1
            end
        end

        if count >= 3 then
            task.wait(0.5)
            return
        end

    until false

end
---------------------------------------------------------------------
-- AUTO CARD PICKER
---------------------------------------------------------------------

local gm = require(game:GetService("ReplicatedStorage").gameClient.net.gamemodesNet)

gm.showInfCards.on(function(cards)

    if not autoPickCards then
        return
    end

    waitForCards()

    local bestCard = nil
    local bestPriority = math.huge

print("---------- CARD PICK DEBUG ----------")

for _, card in ipairs(cards) do

    local p =

    getgenv().priorityContracts[card] or
    getgenv().priorityNormal[card]

    print("Card offered:", card)

    if p then
        print("Priority:", p)
    else
        print("Priority: NONE (not in priority table)")
    end

    if p and p < bestPriority then
        print("-> New best card found:", card)

        bestPriority = p
        bestCard = card
    end

    print("-------------------------------------")

end

    if bestCard then
        print("🔥 Picking:", bestCard)
        gm.selectInfCard.call(bestCard)
    else
        gm.selectInfCard.call(cards[1])
    end

end)
