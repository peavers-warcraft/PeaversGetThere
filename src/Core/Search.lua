local _, PGT = ...

local Search = {}
PGT.Search = Search

Search.MIN_QUERY_LENGTH = 2
Search.MAX_RESULTS = 15

-- Cities beat zones beat dungeons beat city services beat flight points and
-- transports beat generic POIs
local CATEGORY_WEIGHT = {
	city = 1,
	zone = 2,
	dungeon = 3,
	service = 4,
	taxi = 5,
	travel = 5,
	poi = 6,
}

-- Candidates collected before ranking; large enough that the top MAX_RESULTS
-- are stable for any realistic query.
local SCAN_CAP = 200

local function EscapePattern(s)
	return (s:gsub("(%W)", "%%%1"))
end

-- 0 = the name starts with the whole query, 1 = every token starts a word,
-- 2 = plain substring hit.
local function MatchRank(nameLower, query, tokens)
	if nameLower:sub(1, #query) == query then
		return 0
	end
	for _, token in ipairs(tokens) do
		-- The %f[%w] frontier can never match a token starting with a
		-- non-alphanumeric ("'don"); plain substring stands in for those.
		local pattern = token:find("^%w") and ("%f[%w]" .. EscapePattern(token))
			or EscapePattern(token)
		if not nameLower:find(pattern) then
			return 2
		end
	end
	return 1
end

local function Compare(a, b)
	if a.rank ~= b.rank then
		return a.rank < b.rank
	end
	if a.weight ~= b.weight then
		return a.weight < b.weight
	end
	return a.nameLower < b.nameLower
end

-- Parses the "/pgt <place> <x> <y>" power syntax: the last two words must
-- be coordinates on the 0-100 map scale. Returns name, x, y or nil when the
-- message isn't coordinate-shaped (callers fall back to normal handling).
function Search:ParseWaypointCommand(msg)
	local name, x, y = msg:match("^%s*(.-)%s+(%d+%.?%d*)%s+(%d+%.?%d*)%s*$")
	if not name or name == "" then
		return nil
	end
	x, y = tonumber(x), tonumber(y)
	if not x or not y or x > 100 or y > 100 then
		return nil
	end
	return name, x, y
end

-- Returns up to MAX_RESULTS index entries matching every whitespace-separated
-- token of the query (case-insensitive substring AND, any order), ranked by
-- match quality, then category weight, then name.
function Search:Find(query)
	local LocationIndex = PGT.LocationIndex
	if not LocationIndex:IsReady() then
		return {}
	end
	local blob = LocationIndex:GetBlob()

	query = query:lower():match("^%s*(.-)%s*$")
	if #query < self.MIN_QUERY_LENGTH then
		return {}
	end

	local tokens = {}
	for token in query:gmatch("%S+") do
		tokens[#tokens + 1] = token
	end

	-- One scan for the longest token: fewest candidate lines to verify.
	local primary = tokens[1]
	for _, token in ipairs(tokens) do
		if #token > #primary then
			primary = token
		end
	end

	local scored = {}
	local seen = {}
	local init = 1

	while #scored < SCAN_CAP do
		local matchStart = blob:find(primary, init, true)
		if not matchStart then
			break
		end

		local lineEnd = blob:find("\n", matchStart, true) or (#blob + 1)
		local lineStart = matchStart
		while lineStart > 1 and blob:byte(lineStart - 1) ~= 10 do
			lineStart = lineStart - 1
		end

		local line = blob:sub(lineStart, lineEnd - 1)
		local sep = line:find(":", 1, true)
		if sep then
			-- Match against name + category, never the payload id digits
			local text = line:sub(sep + 1)
			local allMatch = true
			for _, token in ipairs(tokens) do
				if not text:find(token, 1, true) then
					allMatch = false
					break
				end
			end

			if allMatch then
				local id = tonumber(line:sub(1, sep - 1))
				local entry = id and LocationIndex:GetEntry(id)
				if id and entry and not seen[id] then
					seen[id] = true
					local nameLower = text:match("^([^\t]*)")
					scored[#scored + 1] = {
						entry = entry,
						nameLower = nameLower,
						rank = MatchRank(nameLower, query, tokens),
						weight = CATEGORY_WEIGHT[entry.category] or 9,
					}
				end
			end
		end

		init = lineEnd + 1
	end

	table.sort(scored, Compare)

	local results = {}
	for i = 1, math.min(#scored, self.MAX_RESULTS) do
		results[i] = scored[i].entry
	end
	return results
end
