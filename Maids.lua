--!strict
--!native
--!optimize 2

--[[

Maids.New(key [any]) --> [Maid] --> :Cleanup will be locked until :Unlock (if key passed)

Methods [Maid]:

	:IsActive() --> [boolean] --> true if :Cleanup has not been called
	
	:Add(item [any]) --> [MaidToken] | nil
		--> adds an item for cleanup
			function which is called first
			RBXScriptConnection --> :Disconnect
			Instance --> :Destroy
			table --> must have :Destroy or :Disconnect
		--> returns nil if the Maid is already cleaned up and cleans the item instantly

	:Cleanup(...) -- cleans up all added items, added functions will receive the optional arguments (...)
		--> After :Cleanup is called all successive items added via :Add will be cleaned up
		
	:Unlock(key [any]) -- unlocks :Cleanup if it was locked with the correct key (duh)

Methods [MaidToken]:

	:Destroy() --> dissociates the item from the Maid (forgets), cleanup will not be performed
	
	:Cleanup(...) --> performs cleanup for the associated item and removes it from the Maid object
		--> the item's cleanup function/method will receive the optional arguments (...)

]]

-- [[ Types ]]

export type MaidToken = typeof(setmetatable({} :: {
	maid : Maid,
	object : any,
}, {} :: MaidTokens))
export type MaidTokens = {
	__index : MaidTokens,
	New : (maid : Maid, object : any) -> MaidToken,
	Destroy : (self : MaidToken) -> (),
	Cleanup : (self : MaidToken, ...any) -> (),
}

export type Maid = typeof(setmetatable({} :: {
	tokens : typeof(setmetatable({} :: { [MaidToken] : boolean }, {} :: { __mode : 'k' })),
	is_cleaned : boolean,
	key : any,
}, {} :: Maids))
export type Maids = {
	__index : Maids,
	New : (key : any) -> Maid,
	IsActive : (self: Maid) -> (boolean),
	Add : (self : Maid, item : any) -> MaidToken | nil,
	Cleanup : (self : Maid, ...any) -> (),
	Unlock : (self : Maid, key : any) -> (),
}

-- [[ Private ]]

local reusableRunner : thread?
local runnerQueue : { { any } } = {}

local function acquireRunnerAndCall(fn : (...any) -> (...any?), ... : any) : () --> call a function temporarily replacing the reusableRunner
	local previousRunner = reusableRunner
	reusableRunner = nil
	fn(...)
	reusableRunner = previousRunner
end

local function safeCallOrDispose(item : any, ... : any) : () --> safely dispose of an item
	local itemType = typeof(item)

	if itemType == 'function' then
		item(...)
		return
	end

	local itemDispose: ((...any) -> ())? =
		itemType == 'RBXScriptConnection' and item.Disconnect or
		itemType == 'Instance' and item.Destroy or
		itemType == 'table' and (
			(type(item.Destroy) == 'function' and item.Destroy) or
			(type(item.Disconnect) == 'function' and item.Disconnect)
		)

	if itemDispose then
		local success, err = pcall(itemDispose, item)
		if not success then
			warn('Error disposing item:', err, '\n', debug.traceback())
		end
	end
end

local function runnerLoop(... : any) : () --> coroutine loop for the reusable runner
	while true do
		-- wait for new arguments if the queue is empty
		while #runnerQueue == 0 do
			local args = {coroutine.yield()}  -- yield until next call
			table.insert(runnerQueue, args)
		end

		-- process all queued calls
		while #runnerQueue > 0 do
			local args: any = table.remove(runnerQueue, 1) -- pop first
			acquireRunnerAndCall(function(...)
				pcall(safeCallOrDispose, ...)
			end, table.unpack(args))
		end
	end
end

local function runInFreeThread(... : any) : () --> spawn or resume the reusable runner
	if not reusableRunner or coroutine.status(reusableRunner) == 'dead' then
		reusableRunner = coroutine.create(runnerLoop)
		coroutine.resume(reusableRunner :: thread)
	end

	-- push the args into the queue
	table.insert(runnerQueue, {...})

	-- resume the coroutine (it will process this call)
	local ok, err = coroutine.resume(reusableRunner :: thread)
	if not ok then
		warn('Reusable runner error:', err, '\n', debug.traceback())
	end
end

local MODULE_NAME = 'Maids'

-- [[ Public ]]

local MaidTokens = {}
MaidTokens.__index = MaidTokens

function MaidTokens.New(maid : Maid, object : any) : MaidToken
	local self : MaidToken = setmetatable({
		maid = maid,
		object = object,
	}, MaidTokens)
	
	return self
end

function MaidTokens:Destroy() : ()
	local self : MaidToken = self
	self.maid.tokens[self] = nil
end

function MaidTokens:Cleanup(... : any) : ()
	local self : MaidToken = self
	
	if self.object == nil then
		return
	end
	
	self.maid.tokens[self] = nil
	safeCallOrDispose(self.object, ...)
	self.object = nil
end

-- integrate the type class
local MaidTokens : MaidTokens = MaidTokens

local Maids = {}
Maids.__index = Maids

function Maids.New(key : any) : Maid
	local self : Maid = setmetatable({
		tokens = setmetatable({}, { __mode = "k" }),
		is_cleaned = false,
		key = key,
	}, Maids)
	
	return self
end

function Maids:IsActive() : boolean
	local self : Maid = self
	return not self.is_cleaned
end

function Maids:Add(item: any) : MaidToken | nil
	local self : Maid = self
	
	if self.is_cleaned == true then
		safeCallOrDispose(item)
		return nil
	end
	
	local itemType = typeof(item)
	
	local failureType : string =
		(itemType == 'table' and (type(item.Destroy) ~= 'function' and type(item.Disconnect) ~= 'function') and
			`[{MODULE_NAME}]: Received table as cleanup object, but couldn't detect a :Destroy() or :Disconnect() method`) or
		((itemType ~= 'function' and itemType ~= 'RBXScriptConnection' and itemType ~= 'Instance') and
			`[{MODULE_NAME}]: Cleanup of type \"{itemType}\" not supported`) :: string
	
	if failureType then
		error(failureType)
	end
	
	local token = MaidTokens.New(self, item)
	self.tokens[token] = true
	
	return token
end

function Maids:Cleanup(... : any) : ()
	local self : Maid = self
	
	if self.key ~= nil then
		error(`[{MODULE_NAME}]: "Cleanup()" is locked for this Maid`)
	end
	
	self.is_cleaned = true
	
	for token in self.tokens do
		token:Cleanup()
	end
end

function Maids:Unlock(key : any) : ()
	local self : Maid = self
	
	if self.key ~= nil and self.key ~= key then
		error(`[{MODULE_NAME}]: Invalid lock key`)
	end
	
	self.key = nil
end

-- integrate the type class
local Maids : Maids = Maids

return Maids
