-- Batata Scanner: budgeted, opaque snapshot cursors and sequenced change replay.
local ADDON,
    NS = ...

local PlayerRead = {}
NS.PlayerRead = PlayerRead

local MAX_OPEN_READS  = 8 -- Bounds public readers' contribution to observation copy-on-write work.
local reads           = setmetatable({}, { __mode = "k" }) -- Opaque tokens own otherwise private request state.

-- Returns whether a profiler sample is a readable finite nonnegative number.
-- @param sample Value returned by the optional millisecond profiler.
local function ValidSample(sample)
    return NS.Readable(sample) and type(sample) == "number" and sample == sample and sample >= 0 and sample < math.huge
end

-- Creates one budget shared by preparation, matching, copying, and change replay.
-- @param milliseconds Optional positive time budget, at most two milliseconds.
local function NewBudget(milliseconds)
    if milliseconds == nil then
        milliseconds = 1
    end
    if not ValidSample(milliseconds) or milliseconds <= 0 or milliseconds > 2 then
        error("budgetMilliseconds must be greater than zero and at most 2", 3)
    end
    local profiler = type(debugprofilestop) == "function" and debugprofilestop or nil
    local succeeded,
        started = false, nil
    if profiler then
        succeeded, started = pcall(profiler)
    end
    local budget = {
        timed           = succeeded and ValidSample(started),
        workUnits       = 0,
        maxOperationMs  = 0,
        exhausted       = false,
    }
    local previous = started
    -- Measures one record/comparison/state operation and yields once either bound is reached.
    function budget:Checkpoint()
        self.workUnits = self.workUnits + 1
        if self.timed then
            local sampled,
                current = pcall(profiler)
            if sampled and ValidSample(current) and current >= previous then
                self.maxOperationMs  = math.max(self.maxOperationMs, current - previous)
                self.elapsedMs       = current - started
                previous             = current
                self.exhausted       = self.elapsedMs >= milliseconds * 0.9
            else
                self.timed      = false
                self.elapsedMs  = nil
            end
        end
        self.exhausted = self.exhausted or self.workUnits >= (self.timed and 4000 or 64)
        return self.exhausted
    end
    return budget
end

-- Finds private cursor state without reading any caller-controlled token fields.
-- @param cursor Opaque token returned by OpenPlayerCursor.
local function GetRead(cursor)
    local state = NS.Accessible(cursor) and reads[cursor]
    if not state then
        error("cursor must be an open Batata Scanner player cursor", 3)
    end
    return state
end

-- Releases snapshot/journal ownership and makes a lost history boundary explicit.
-- @param state Private cursor state to invalidate.
-- @param reason Stable reason string for incremental recovery.
local function ResetRead(state, reason)
    if state.request then
        NS.Store:ClosePlayerRead(state.request)
        state.request = nil
    end
    state.phase   = "resetRequired"
    state.reason  = reason
end

-- Captures a fixed feed endpoint and reads transitions without chasing ongoing mutations.
-- @param state Private cursor state whose feed position advances.
-- @param result Detached result receiving copied upserts and removal entries.
-- @param budget Shared advancement budget.
local function ReadChanges(state, result, budget)
    if not state.targetSequence then
        state.targetSequence  = NS.Store:GetReadPosition()
        state.targetRevision  = NS.db.revision
    end
    while state.sequence < state.targetSequence and #result.changes < state.limit and not budget.exhausted do
        local sequence  = state.sequence + 1
        local change    = NS.Store:GetReadChange(sequence, state.filters)
        if change == nil then
            ResetRead(state, "historyExpired")
            budget:Checkpoint()
            return
        end
        if change then
            result.changes[#result.changes + 1] = change
        end
        state.sequence = sequence
        budget:Checkpoint()
    end
    if state.sequence == state.targetSequence then
        result.caughtUp       = true
        state.changeRevision  = state.targetRevision
        state.targetSequence  = nil
        state.targetRevision  = nil
    end
end

-- Publishes only bounded result arrays and scalar progress; no final population copy is made.
-- @param state Private read state used for detached metadata.
-- @param result Bounded output arrays accumulated during this call.
-- @param budget Budget whose final overhead is included in diagnostics.
local function Finish(state, result, budget)
    result.state             = state.phase
    result.reason            = state.reason
    result.total             = state.total
    result.limit             = state.limit
    result.revision          = state.snapshotRevision
    result.snapshotSequence  = state.snapshotSequence
    result.snapshotComplete  = state.snapshotComplete
    result.hasMore           = not state.snapshotComplete and state.phase ~= "resetRequired"
    result.sequence          = state.sequence
    result.throughSequence   = state.targetSequence or state.sequence
    result.throughRevision   = state.targetRevision or state.changeRevision
    budget:Checkpoint()
    result.timed           = budget.timed
    result.elapsedMs       = budget.elapsedMs
    result.maxOperationMs  = budget.timed and budget.maxOperationMs or nil
    result.workUnits       = budget.workUnits
    return result
end

-- Opens a stable exhaustive read in constant work relative to retained database size.
-- @param filters Optional public filters, captured for snapshot and change replay.
-- @param options Optional standard sort, descending, offset, and page limit settings.
function PlayerRead:Open(filters, options)
    local count = 0
    for cursor in pairs(reads) do
        count = count + 1
    end
    if count >= MAX_OPEN_READS then
        error("at most 8 player cursors may be open; close unused cursors", 2)
    end
    local request,
        validatedFilters,
        offset,
        limit,
        sequence,
        generation = NS.Store:CreatePlayerRead(filters, options)
    local cursor = setmetatable({}, {
        __newindex = function()
            error("Batata Scanner player cursors are opaque", 2)
        end,
        __metatable = "Batata Scanner player cursor",
    })
    reads[cursor] = {
        request           = request,
        filters           = validatedFilters,
        nextIndex         = offset + 1,
        limit             = limit,
        sequence          = sequence,
        snapshotSequence  = sequence,
        snapshotRevision  = request.revision,
        changeRevision    = request.revision,
        generation        = generation,
        phase             = "preparing",
        snapshotComplete  = false,
    }
    return cursor
end

-- Advances initial retrieval, or optionally just its feed while initial retrieval is still running.
-- @param cursor Opaque read token.
-- @param milliseconds Optional positive time budget at most two milliseconds.
-- @param changesOnly Internal selector used by ReadPlayerChanges.
function PlayerRead:Advance(cursor, milliseconds, changesOnly)
    local state   = GetRead(cursor)
    local budget  = NewBudget(milliseconds)
    local result  = { players = {}, changes = {}, offset = state.nextIndex - 1, caughtUp = false }
    local sequence,
        generation = NS.Store:GetReadPosition()
    if state.generation ~= generation and state.phase ~= "resetRequired" then
        ResetRead(state, "collectionReloaded")
    end
    if state.phase == "resetRequired" then
        return Finish(state, result, budget)
    end
    if not changesOnly and state.phase == "preparing" then
        if state.request:Step(budget) then
            state.total  = state.request.total
            state.phase  = "snapshot"
        end
    end
    if not changesOnly and state.phase == "snapshot" then
        while state.nextIndex <= state.total and #result.players < state.limit and not budget.exhausted do
            result.players[#result.players + 1]  = state.request:GetPlayer(state.nextIndex)
            state.nextIndex                      = state.nextIndex + 1
            budget:Checkpoint()
        end
        if state.nextIndex > state.total then
            state.snapshotComplete  = true
            state.phase             = "changes"
            state.request:Cancel()
        end
    end
    if changesOnly or state.phase == "changes" then
        ReadChanges(state, result, budget)
    end
    return Finish(state, result, budget)
end

-- Closes an opaque read token; repeated closure returns false.
-- @param cursor Read token whose retained versions can be released.
function PlayerRead:Close(cursor)
    local state = NS.Accessible(cursor) and reads[cursor]
    if not state then
        return false
    end
    if state.request then
        NS.Store:ClosePlayerRead(state.request)
    end
    reads[cursor] = nil
    return true
end
