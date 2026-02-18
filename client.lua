local propModel <const> = `ches_game`
local spawnCoords <const> = vector3(1480.6290, -3221.5500, 117.1789)
local spawnHeading <const> = 0.0

local pieceModels <const> = {
    pion     = `gw_pion`,
    tower    = `gw_tower`,
    cavalier = `gw_cavalier`,
    fou      = `gw_fou`,
    renne    = `gw_renne`,
    roy      = `gw_roy`,
}

local backRank <const> = { 'tower', 'cavalier', 'fou', 'renne', 'roy', 'fou', 'cavalier', 'tower' }

local prop = nil
local drawGrid = false
local isPlaying = false

local boardMin = nil
local boardMax = nil
local cellSize = nil
local pieceBaseZ = nil

local GRID <const> = 8
local BORDER_RATIO <const> = 0.08
local PIECE_Z_OFFSET <const> = -0.05
local LERP_DURATION <const> = 1.5
local LERP_ARC <const> = 0.08
local PAUSE_BETWEEN_MOVES <const> = 1.0
local PAUSE_BEFORE_RESET <const> = 5.0

local cellCenters = {}
local cellCorners = {}
local board = {}

local cachedForward = nil
local cachedRight = nil
local cachedUp = nil
local cachedPos = nil
local cachedBoardCenter = nil

local capturedWhiteCount = 0
local capturedBlackCount = 0
local capturedEntities = {}

-- Move path highlight
local currentMovePath = {}
local movePathColor = {r = 0, g = 0, b = 0}

local columns <const> = { 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H' }

-- Scenario: Partie Italienne avec captures (10 coups / 20 demi-coups)
local scenario <const> = {
    {5, 2, 5, 4},   -- e2->e4
    {5, 7, 5, 5},   -- e7->e5
    {6, 1, 3, 4},   -- Ff1->c4
    {2, 8, 3, 6},   -- Cb8->c6
    {4, 2, 4, 3},   -- d2->d3
    {6, 8, 3, 5},   -- Ff8->c5
    {3, 1, 7, 5},   -- Cc1->g5
    {4, 7, 4, 6},   -- d7->d6
    {2, 1, 3, 3},   -- Cb1->c3
    {7, 8, 6, 6},   -- Cg8->f6
    {3, 3, 4, 5},   -- Cc3->d5
    {6, 6, 4, 5},   -- Cf6xd5
    {5, 4, 4, 5},   -- e4xd5
    {3, 6, 4, 4},   -- Cc6->d4
    {3, 2, 3, 3},   -- c2->c3
    {4, 4, 6, 3},   -- Cd4->f3
    {7, 2, 6, 3},   -- g2xf3
    {3, 5, 6, 2},   -- Cc5xf2
    {5, 1, 4, 2},   -- Re1->d2
    {4, 8, 7, 5},   -- Dd8xg5
}

-- Text entries
for col = 1, GRID do
    for row = 1, GRID do
        AddTextEntry(('CHESS_%d_%d'):format(col, row), columns[col] .. tostring(row))
    end
end
for col = 1, GRID do
    AddTextEntry(('CHESS_COL_%d'):format(col), columns[col])
end
for row = 1, GRID do
    AddTextEntry(('CHESS_ROW_%d'):format(row), tostring(row))
end

local function loadModel(model)
    RequestModel(model)
    while not HasModelLoaded(model) do
        Wait(0)
    end
end

local function getWorldPos(entity, localOffset)
    local forward, right, up, pos = GetEntityMatrix(entity)
    return vector3(
        pos.x + right.x * localOffset.x + forward.x * localOffset.y + up.x * localOffset.z,
        pos.y + right.y * localOffset.x + forward.y * localOffset.y + up.y * localOffset.z,
        pos.z + right.z * localOffset.x + forward.z * localOffset.y + up.z * localOffset.z
    )
end

local function drawLine3D(from, to, r, g, b, a)
    DrawLine(from.x, from.y, from.z, to.x, to.y, to.z, r, g, b, a)
end

local function drawText2D(key, sx, sy, scale, r, g, b, a)
    SetTextScale(0.0, scale)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(r, g, b, a)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText(key)
    EndTextCommandDisplayText(sx, sy)
end

local function drawTextString(text, sx, sy, scale, r, g, b, a)
    SetTextScale(0.0, scale)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(r, g, b, a)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(sx, sy)
end

local function cachePositions()
    cellCenters = {}
    cellCorners = {}

    for col = 1, GRID + 1 do
        cellCorners[col] = {}
        for row = 1, GRID + 1 do
            local localX = boardMin.x + (col - 1) * cellSize.x
            local localY = boardMin.y + (row - 1) * cellSize.y
            local localZ = boardMin.z + 0.005
            cellCorners[col][row] = getWorldPos(prop, vector3(localX, localY, localZ))
        end
    end

    for col = 1, GRID do
        cellCenters[col] = {}
        for row = 1, GRID do
            local localX = boardMin.x + (col - 1) * cellSize.x + cellSize.x * 0.5
            local localY = boardMin.y + (row - 1) * cellSize.y + cellSize.y * 0.5
            local localZ = boardMin.z + 0.005
            cellCenters[col][row] = getWorldPos(prop, vector3(localX, localY, localZ))
        end
    end

    cachedForward, cachedRight, cachedUp, cachedPos = GetEntityMatrix(prop)

    local centerLocal = vector3(
        (boardMin.x + boardMax.x) * 0.5,
        (boardMin.y + boardMax.y) * 0.5,
        boardMin.z + 0.005
    )
    cachedBoardCenter = getWorldPos(prop, centerLocal)
end

local function getCellWorldPos(col, row)
    local center = cellCenters[col][row]
    return vector3(center.x, center.y, pieceBaseZ)
end

local function getCapturePos(side, index)
    local row = math.floor((index - 1) / 2)
    local col = (index - 1) % 2
    local offsetX, offsetY

    if side == 'white' then
        offsetX = boardMin.x - 0.15 - col * cellSize.x * 0.6
        offsetY = boardMin.y + row * cellSize.y * 0.7
    else
        offsetX = boardMax.x + 0.15 + col * cellSize.x * 0.6
        offsetY = boardMax.y - row * cellSize.y * 0.7
    end

    local pos = getWorldPos(prop, vector3(offsetX, offsetY, boardMin.z))
    return vector3(pos.x, pos.y, pieceBaseZ)
end

-- Build move path cells for visualization
local function getMovePath(pieceType, fromCol, fromRow, toCol, toRow)
    local path = {}

    -- Start cell (green)
    path[#path + 1] = {col = fromCol, row = fromRow, kind = 'from'}

    if pieceType == 'cavalier' then
        -- Knight: show L-shape path
        local dc = toCol - fromCol
        local dr = toRow - fromRow

        -- Two possible L paths, pick one that makes sense
        -- Option 1: move cols first, then rows
        -- Option 2: move rows first, then cols
        if math.abs(dc) == 2 then
            -- Moved 2 cols, 1 row -> show intermediate col step
            local midCol = fromCol + dc
            local midRow = fromRow
            path[#path + 1] = {col = fromCol + (dc > 0 and 1 or -1), row = fromRow, kind = 'path'}
            path[#path + 1] = {col = midCol, row = midRow, kind = 'path'}
        else
            -- Moved 1 col, 2 rows -> show intermediate row step
            local midCol = fromCol
            local midRow = fromRow + (dr > 0 and 1 or -1)
            path[#path + 1] = {col = midCol, row = midRow, kind = 'path'}
            path[#path + 1] = {col = midCol, row = fromRow + (dr > 0 and 2 or -2), kind = 'path'}
        end
    elseif pieceType == 'fou' then
        -- Bishop: show diagonal path
        local dc = toCol > fromCol and 1 or -1
        local dr = toRow > fromRow and 1 or -1
        local c, r = fromCol + dc, fromRow + dr
        while c ~= toCol and r ~= toRow do
            path[#path + 1] = {col = c, row = r, kind = 'path'}
            c = c + dc
            r = r + dr
        end
    elseif pieceType == 'tower' then
        -- Rook: show straight path
        if fromCol == toCol then
            local dr = toRow > fromRow and 1 or -1
            for r = fromRow + dr, toRow - dr, dr do
                path[#path + 1] = {col = fromCol, row = r, kind = 'path'}
            end
        else
            local dc = toCol > fromCol and 1 or -1
            for c = fromCol + dc, toCol - dc, dc do
                path[#path + 1] = {col = c, row = fromRow, kind = 'path'}
            end
        end
    elseif pieceType == 'renne' then
        -- Queen: show path (diagonal or straight)
        local dc = toCol == fromCol and 0 or (toCol > fromCol and 1 or -1)
        local dr = toRow == fromRow and 0 or (toRow > fromRow and 1 or -1)
        local c, r = fromCol + dc, fromRow + dr
        while c ~= toCol or r ~= toRow do
            path[#path + 1] = {col = c, row = r, kind = 'path'}
            c = c + dc
            r = r + dr
        end
    elseif pieceType == 'pion' then
        -- Pawn: show straight path
        local dr = toRow > fromRow and 1 or -1
        if fromCol ~= toCol then
            -- Diagonal capture
            path[#path + 1] = {col = fromCol, row = fromRow + dr, kind = 'path'}
        elseif math.abs(toRow - fromRow) == 2 then
            path[#path + 1] = {col = fromCol, row = fromRow + dr, kind = 'path'}
        end
    end

    -- End cell (red if capture, blue otherwise)
    path[#path + 1] = {col = toCol, row = toRow, kind = 'to'}

    return path
end

local function deleteAllEntities()
    for col = 1, GRID do
        if board[col] then
            for row = 1, GRID do
                if board[col][row] and board[col][row].entity and DoesEntityExist(board[col][row].entity) then
                    DeleteEntity(board[col][row].entity)
                end
            end
        end
    end
    board = {}

    for i = 1, #capturedEntities do
        if capturedEntities[i] and DoesEntityExist(capturedEntities[i]) then
            DeleteEntity(capturedEntities[i])
        end
    end
    capturedEntities = {}
    capturedWhiteCount = 0
    capturedBlackCount = 0
end

local function spawnPieceOnBoard(name, col, row, side)
    local model = pieceModels[name]
    local center = cellCenters[col][row]
    local heading = side == 'white' and spawnHeading or (spawnHeading + 180.0)
    local entity = CreateObject(model, center.x, center.y, center.z + 5.0, false, false, false)
    SetEntityHeading(entity, heading)
    PlaceObjectOnGroundProperly(entity)
    FreezeEntityPosition(entity, true)

    if not board[col] then board[col] = {} end
    board[col][row] = { entity = entity, type = name, side = side }
end

local function initBoard()
    deleteAllEntities()

    for _, model in pairs(pieceModels) do
        loadModel(model)
    end

    for col = 1, GRID do
        spawnPieceOnBoard(backRank[col], col, 1, 'white')
    end
    for col = 1, GRID do
        spawnPieceOnBoard('pion', col, 2, 'white')
    end
    for col = 1, GRID do
        spawnPieceOnBoard('pion', col, 7, 'black')
    end
    for col = 1, GRID do
        spawnPieceOnBoard(backRank[col], col, 8, 'black')
    end

    for _, model in pairs(pieceModels) do
        SetModelAsNoLongerNeeded(model)
    end

    print('Board initialized with 32 pieces.')
end

local function lerpPiece(entity, fromPos, toPos, duration)
    -- Read the real Z the entity is at right now (placed by GTA)
    local realZ = GetEntityCoords(entity).z
    local startTime = GetGameTimer()
    local durationMs = duration * 1000

    FreezeEntityPosition(entity, false)
    SetEntityCollision(entity, false, false)

    while true do
        local elapsed = GetGameTimer() - startTime
        local t = math.min(elapsed / durationMs, 1.0)
        t = t * t * (3.0 - 2.0 * t)

        local x = fromPos.x + (toPos.x - fromPos.x) * t
        local y = fromPos.y + (toPos.y - fromPos.y) * t
        local arc = math.sin(t * math.pi) * LERP_ARC
        local z = realZ + arc

        SetEntityCoordsNoOffset(entity, x, y, z, false, false, false)

        if t >= 1.0 then break end
        Wait(0)
    end

    -- Place at destination properly
    SetEntityCoordsNoOffset(entity, toPos.x, toPos.y, toPos.z + 5.0, false, false, false)
    SetEntityCollision(entity, true, true)
    PlaceObjectOnGroundProperly(entity)
    FreezeEntityPosition(entity, true)
end

local function playMove(fromCol, fromRow, toCol, toRow)
    local piece = board[fromCol] and board[fromCol][fromRow]
    if not piece then
        print(('No piece at %s%d'):format(columns[fromCol], fromRow))
        return
    end

    local fromPos = getCellWorldPos(fromCol, fromRow)
    local toPos = getCellWorldPos(toCol, toRow)

    -- Set move path for visualization
    currentMovePath = getMovePath(piece.type, fromCol, fromRow, toCol, toRow)
    if piece.side == 'white' then
        movePathColor = {r = 50, g = 150, b = 255}
    else
        movePathColor = {r = 255, g = 100, b = 50}
    end

    local target = board[toCol] and board[toCol][toRow]

    -- Move our piece to the target cell first
    lerpPiece(piece.entity, fromPos, toPos, LERP_DURATION)

    -- Update board
    if not board[toCol] then board[toCol] = {} end
    board[toCol][toRow] = piece
    board[fromCol][fromRow] = nil

    -- Then eject the captured piece off the board
    if target then
        local capturePos
        if target.side == 'white' then
            capturedWhiteCount = capturedWhiteCount + 1
            capturePos = getCapturePos('white', capturedWhiteCount)
        else
            capturedBlackCount = capturedBlackCount + 1
            capturePos = getCapturePos('black', capturedBlackCount)
        end

        local targetPos = getCellWorldPos(toCol, toRow)
        lerpPiece(target.entity, targetPos, capturePos, 1.0)
        capturedEntities[#capturedEntities + 1] = target.entity
    end

    -- Clear path after move
    currentMovePath = {}
end

local function playScenario()
    while isPlaying do
        initBoard()
        Wait(2000)

        for i = 1, #scenario do
            if not isPlaying then return end

            local move = scenario[i]
            print(('Move %d: %s%d -> %s%d'):format(
                i, columns[move[1]], move[2], columns[move[3]], move[4]
            ))
            playMove(move[1], move[2], move[3], move[4])

            if not isPlaying then return end
            Wait(PAUSE_BETWEEN_MOVES * 1000)
        end

        if not isPlaying then return end
        print('Scenario complete. Restarting in 5 seconds...')
        Wait(PAUSE_BEFORE_RESET * 1000)
    end
end

local function spawnProp()
    loadModel(propModel)

    prop = CreateObject(propModel, spawnCoords.x, spawnCoords.y, spawnCoords.z, false, false, false)
    SetEntityHeading(prop, spawnHeading)
    FreezeEntityPosition(prop, true)
    SetModelAsNoLongerNeeded(propModel)

    local min, max = GetModelDimensions(propModel)

    local sizeX = max.x - min.x
    local sizeY = max.y - min.y

    local borderX = sizeX * BORDER_RATIO
    local borderY = sizeY * BORDER_RATIO

    boardMin = vector3(min.x + borderX, min.y + borderY, max.z)
    boardMax = vector3(max.x - borderX, max.y - borderY, max.z)

    local playableX = boardMax.x - boardMin.x
    local playableY = boardMax.y - boardMin.y
    cellSize = vector2(playableX / GRID, playableY / GRID)

    cachePositions()

    -- Spawn a test pion, let GTA place it, read its real Z
    local testModel = pieceModels.pion
    loadModel(testModel)
    local bc = cachedBoardCenter
    local testObj = CreateObject(testModel, bc.x, bc.y, bc.z + 5.0, false, false, false)
    PlaceObjectOnGroundProperly(testObj)
    FreezeEntityPosition(testObj, true)
    Wait(100)
    pieceBaseZ = GetEntityCoords(testObj).z
    print(('Test pion Z after PlaceOnGround: %.4f'):format(pieceBaseZ))
    DeleteEntity(testObj)
    SetModelAsNoLongerNeeded(testModel)

    print(('=== Chess Board ==='))
    print(('Piece Base Z: %.4f'):format(pieceBaseZ))
    print(('Cell Size: %.4f x %.4f'):format(cellSize.x, cellSize.y))

    initBoard()
    drawGrid = true
end

local function deleteAll()
    isPlaying = false
    drawGrid = false
    currentMovePath = {}
    deleteAllEntities()
    if prop and DoesEntityExist(prop) then
        DeleteEntity(prop)
        prop = nil
    end
end

-- Draw grid lines + move path
CreateThread(function()
    while true do
        if drawGrid and prop and DoesEntityExist(prop) then
            for col = 1, GRID do
                for row = 1, GRID do
                    local c0 = cellCorners[col][row]
                    local c1 = cellCorners[col + 1][row]
                    local c2 = cellCorners[col + 1][row + 1]
                    local c3 = cellCorners[col][row + 1]

                    local isWhite = (col + row) % 2 == 0
                    local r, g, b = 200, 200, 200
                    if not isWhite then
                        r, g, b = 139, 90, 43
                    end

                    drawLine3D(c0, c1, r, g, b, 255)
                    drawLine3D(c1, c2, r, g, b, 255)
                    drawLine3D(c2, c3, r, g, b, 255)
                    drawLine3D(c3, c0, r, g, b, 255)

                    local center = cellCenters[col][row]
                    local s = 0.02
                    drawLine3D(
                        vector3(center.x - cachedRight.x * s, center.y - cachedRight.y * s, center.z),
                        vector3(center.x + cachedRight.x * s, center.y + cachedRight.y * s, center.z),
                        r, g, b, 150
                    )
                    drawLine3D(
                        vector3(center.x - cachedForward.x * s, center.y - cachedForward.y * s, center.z),
                        vector3(center.x + cachedForward.x * s, center.y + cachedForward.y * s, center.z),
                        r, g, b, 150
                    )
                end
            end

            local b0 = cellCorners[1][1]
            local b1 = cellCorners[GRID + 1][1]
            local b2 = cellCorners[GRID + 1][GRID + 1]
            local b3 = cellCorners[1][GRID + 1]

            drawLine3D(b0, b1, 255, 0, 0, 255)
            drawLine3D(b1, b2, 255, 0, 0, 255)
            drawLine3D(b2, b3, 255, 0, 0, 255)
            drawLine3D(b3, b0, 255, 0, 0, 255)

            local cornerHeight = 0.15
            for _, corner in ipairs({b0, b1, b2, b3}) do
                local top = vector3(corner.x, corner.y, corner.z + cornerHeight)
                drawLine3D(corner, top, 255, 255, 0, 255)
            end

            -- Draw move path highlight
            local path = currentMovePath
            if #path > 0 then
                local pr, pg, pb = movePathColor.r, movePathColor.g, movePathColor.b
                for idx, cell in ipairs(path) do
                    if cell.col >= 1 and cell.col <= GRID and cell.row >= 1 and cell.row <= GRID then
                        local cc0 = cellCorners[cell.col][cell.row]
                        local cc1 = cellCorners[cell.col + 1][cell.row]
                        local cc2 = cellCorners[cell.col + 1][cell.row + 1]
                        local cc3 = cellCorners[cell.col][cell.row + 1]

                        local hr, hg, hb = pr, pg, pb
                        if cell.kind == 'from' then
                            hr, hg, hb = 0, 255, 0
                        elseif cell.kind == 'to' then
                            hr, hg, hb = 255, 50, 50
                        end

                        -- Double thickness by drawing offset lines
                        drawLine3D(cc0, cc1, hr, hg, hb, 255)
                        drawLine3D(cc1, cc2, hr, hg, hb, 255)
                        drawLine3D(cc2, cc3, hr, hg, hb, 255)
                        drawLine3D(cc3, cc0, hr, hg, hb, 255)
                        drawLine3D(cc0, cc2, hr, hg, hb, 200)
                        drawLine3D(cc1, cc3, hr, hg, hb, 200)

                        -- Vertical pillars at corners
                        local h = 0.06
                        drawLine3D(cc0, vector3(cc0.x, cc0.y, cc0.z + h), hr, hg, hb, 255)
                        drawLine3D(cc1, vector3(cc1.x, cc1.y, cc1.z + h), hr, hg, hb, 255)
                        drawLine3D(cc2, vector3(cc2.x, cc2.y, cc2.z + h), hr, hg, hb, 255)
                        drawLine3D(cc3, vector3(cc3.x, cc3.y, cc3.z + h), hr, hg, hb, 255)
                    end
                end

                -- Draw arrows between path cells
                for idx = 1, #path - 1 do
                    local from = cellCenters[path[idx].col][path[idx].row]
                    local to = cellCenters[path[idx + 1].col][path[idx + 1].row]
                    local z = from.z + 0.03
                    drawLine3D(
                        vector3(from.x, from.y, z),
                        vector3(to.x, to.y, z),
                        pr, pg, pb, 255
                    )
                end
            end
        end
        Wait(0)
    end
end)

-- Draw text labels
CreateThread(function()
    while true do
        if drawGrid and prop and DoesEntityExist(prop) then
            for col = 1, GRID do
                for row = 1, GRID do
                    local center = cellCenters[col][row]
                    local onScreen, sx, sy = GetScreenCoordFromWorldCoord(center.x, center.y, center.z)
                    if onScreen then
                        drawText2D(('CHESS_%d_%d'):format(col, row), sx, sy, 0.22, 255, 255, 255, 255)
                        drawTextString(
                            ('%.2f, %.2f'):format(center.x, center.y),
                            sx, sy + 0.018, 0.15, 180, 180, 180, 200
                        )
                    end
                end
            end

            for col = 1, GRID do
                local pos = cellCenters[col][1]
                local borderPos = vector3(
                    pos.x - cachedForward.x * cellSize.y * 0.8,
                    pos.y - cachedForward.y * cellSize.y * 0.8,
                    pos.z
                )
                local onScreen, sx, sy = GetScreenCoordFromWorldCoord(borderPos.x, borderPos.y, borderPos.z)
                if onScreen then
                    drawText2D(('CHESS_COL_%d'):format(col), sx, sy, 0.30, 255, 200, 50, 255)
                end
            end

            for row = 1, GRID do
                local pos = cellCenters[1][row]
                local borderPos = vector3(
                    pos.x - cachedRight.x * cellSize.x * 0.8,
                    pos.y - cachedRight.y * cellSize.x * 0.8,
                    pos.z
                )
                local onScreen, sx, sy = GetScreenCoordFromWorldCoord(borderPos.x, borderPos.y, borderPos.z)
                if onScreen then
                    drawText2D(('CHESS_ROW_%d'):format(row), sx, sy, 0.30, 255, 200, 50, 255)
                end
            end

            local corners = {
                {pos = cellCorners[1][1], label = 'A1 corner'},
                {pos = cellCorners[GRID + 1][1], label = 'H1 corner'},
                {pos = cellCorners[GRID + 1][GRID + 1], label = 'H8 corner'},
                {pos = cellCorners[1][GRID + 1], label = 'A8 corner'},
            }
            for _, c in ipairs(corners) do
                local top = vector3(c.pos.x, c.pos.y, c.pos.z + 0.17)
                local onScr, csx, csy = GetScreenCoordFromWorldCoord(top.x, top.y, top.z)
                if onScr then
                    drawTextString(c.label, csx, csy, 0.18, 255, 255, 0, 255)
                    drawTextString(
                        ('%.2f, %.2f'):format(c.pos.x, c.pos.y),
                        csx, csy + 0.017, 0.15, 255, 255, 0, 200
                    )
                end
            end

            -- Move path labels
            local path = currentMovePath
            for _, cell in ipairs(path) do
                if cell.col >= 1 and cell.col <= GRID and cell.row >= 1 and cell.row <= GRID then
                    local center = cellCenters[cell.col][cell.row]
                    local onScreen, sx, sy = GetScreenCoordFromWorldCoord(center.x, center.y, center.z + 0.07)
                    if onScreen then
                        local label = ''
                        if cell.kind == 'from' then
                            label = 'FROM'
                            drawTextString(label, sx, sy, 0.20, 0, 255, 0, 255)
                        elseif cell.kind == 'to' then
                            label = 'TO'
                            drawTextString(label, sx, sy, 0.20, 255, 50, 50, 255)
                        else
                            label = 'PATH'
                            drawTextString(label, sx, sy, 0.17, movePathColor.r, movePathColor.g, movePathColor.b, 220)
                        end
                    end
                end
            end
        end
        Wait(0)
    end
end)

RegisterCommand('chess:spawn', function()
    if prop and DoesEntityExist(prop) then
        print('Chess board already spawned.')
        return
    end
    spawnProp()
end, false)

RegisterCommand('chess:grid', function()
    drawGrid = not drawGrid
    print('Grid display: ' .. tostring(drawGrid))
end, false)

RegisterCommand('chess:play', function()
    if not prop or not DoesEntityExist(prop) then
        print('Spawn the board first with /chess:spawn')
        return
    end

    if isPlaying then
        isPlaying = false
        print('Scenario stopped.')
        return
    end

    isPlaying = true
    print('Scenario started.')
    CreateThread(playScenario)
end, false)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    deleteAll()
end)
