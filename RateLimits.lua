--!strict
--!native
--!optimize 2

--[[

RateLimits.New( number of actions allowed per second, sliding period enabled )

	:CheckRate() --> returns true if the action is allowed depending on the last time :CheckRate() was called

	:CleanSource( any ) --> forgets about the source
	
	:Cleanup() --> forgets about all the sources
	
	:Destroy() --> forgets about the rate limit

]]

-- [[ Types ]]

export type PlayerReferences = { [Player] : boolean }
export type RateLimitReferences = { [RateLimit] : boolean }

export type RateLimit = typeof(setmetatable({} :: {
	sources : { [any] : number },
	rate_period : number,
	is_full_wait : boolean,
}, {} :: RateLimits))
export type RateLimits = {
	__index : RateLimits,
	New : (rate : number, is_full_wait : boolean?) -> RateLimit,
	CheckRate : (self : RateLimit, source : any) -> boolean,
	CleanSource : (self : RateLimit, source : Player?) -> (),
	Cleanup : (self : RateLimit) -> (),
	Destroy : (self : RateLimit) -> (),
}

-- [[ Private ]]

local Players = game:GetService("Players")

local PlayerReferences : PlayerReferences = {}
local RateLimitReferences : RateLimitReferences = {}

-- index to disallow colliding index assignments
local DEFAULT_SOURCE : any = newproxy(true)

local max = math.max
local clock = os.clock
local clear = table.clear

-- [[ Public ]]

local RateLimits = {}
RateLimits.__index = RateLimits

function RateLimits.New(rate : number, is_full_wait : boolean?) : RateLimit
	if rate <= 0 then
		error("[RateLimit]: Invalid rate")
	end

	local self = setmetatable({
		sources = {},
		rate_period = 1 / rate,
		is_full_wait = is_full_wait == true,
	}, RateLimits)

	RateLimitReferences[self] = true

	return self
end

function RateLimits:CheckRate(source : any) : boolean --> whether event should be processed
	local self : RateLimit = self

	local sources = self.sources
	local os_clock : number = clock()

	local source : any = source or DEFAULT_SOURCE

	local rate_time : number = sources[source]
	local rate_period = self.rate_period
	
	if rate_time == nil then
		if typeof(source) == "Instance" and source:IsA("Player") and PlayerReferences[source] == nil then
			return false
		end
		sources[source] = os_clock + rate_period
		return true
	end
	
	-- sliding period or not
	if not self.is_full_wait then
		local next_allowed_time = rate_time + rate_period
		if os_clock < next_allowed_time then
			sources[source] = next_allowed_time
			return false
		else
			sources[source] = os_clock + rate_period
			return true
		end
	else
		if rate_time <= os_clock then
			sources[source] = os_clock + rate_period
			return true
		else
			return false
		end
	end
end

function RateLimits:CleanSource(source : Player?) : () --> forgets source; must be called for any object that has been passed to RateLimit:CheckRate() and is not needed anymore
	local self : RateLimit = self	
	self.sources[source] = nil
end

function RateLimits:Cleanup() : () --> forgets all sources
	local self : RateLimit = self
	clear(self.sources)
end

function RateLimits:Destroy() : () --> make the RateLimit module forget about this RateLimit object
	local self : RateLimit = self	
	RateLimitReferences[self] = nil
end

-- [[ Init ]]

for _, player : Player in Players:GetPlayers() do
	PlayerReferences[player] = true
end

Players.PlayerAdded:Connect(function(player : Player)
	PlayerReferences[player] = true
end)

Players.PlayerRemoving:Connect(function(player : Player)
	PlayerReferences[player] = nil
	for rate_limit in RateLimitReferences do
		rate_limit.sources[player] = nil
	end
end)

-- integrate the type class
local RateLimits : RateLimits = RateLimits

return RateLimits
