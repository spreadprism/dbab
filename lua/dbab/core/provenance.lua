--- Deciding whether a result may be edited.
---
--- A result set is a projection. `SELECT a.name, b.total FROM a JOIN b ...` has
--- no single row to write back to, so the editing affordance has to be *earned*
--- by the query and refused otherwise.
---
--- With a CLI subprocess there is no `PQftable` to ask, so the query itself is
--- all we have. This analysis is therefore deliberately conservative: a false
--- negative costs the user nothing, a false positive writes to the wrong table.
---@class Dbab.Provenance
local M = {}

--- Anything in this list means we cannot say which row a cell came from.
local DISQUALIFIERS = {
	{ pattern = "%f[%w]join%f[%W]", reason = "query joins tables" },
	{ pattern = "%f[%w]union%f[%W]", reason = "query uses UNION" },
	{ pattern = "%f[%w]intersect%f[%W]", reason = "query uses INTERSECT" },
	{ pattern = "%f[%w]except%f[%W]", reason = "query uses EXCEPT" },
	{ pattern = "%f[%w]group%s+by%f[%W]", reason = "query groups rows" },
	{ pattern = "%f[%w]having%f[%W]", reason = "query uses HAVING" },
	{ pattern = "%f[%w]distinct%f[%W]", reason = "query uses DISTINCT" },
	{ pattern = "%f[%w]over%s*%(", reason = "query uses a window function" },
	{ pattern = "%f[%w]with%f[%W]", reason = "query uses a CTE" },
}

--- Aggregates collapse rows, so a cell no longer maps to one.
local AGGREGATES = { "count", "sum", "avg", "min", "max", "array_agg", "string_agg", "group_concat" }

--- Strip string literals and comments so their contents cannot be mistaken for
--- SQL keywords -- `SELECT 'inner join' FROM t` is a perfectly editable query.
---@param query string
---@return string
local function strip_noise(query)
	local out = query:gsub("%-%-[^\n]*", " ")
	out = out:gsub("/%*.-%*/", " ")
	out = out:gsub("'[^']*'", "''")
	out = out:gsub('"[^"]*"', '""')
	out = out:gsub("`[^`]*`", "``")

	return out
end

--- Collapse whitespace but keep the original case: identifiers are extracted
--- from this, and on Linux MySQL table names are case-sensitive.
---@param query string
---@return string
local function normalize(query)
	local collapsed = strip_noise(query):gsub("%s+", " "):gsub(";%s*$", "")

	return vim.trim(collapsed)
end

--- Split a select list on top-level commas only, so `coalesce(a, b)` stays whole.
---@param list string
---@return string[]
local function split_columns(list)
	local parts = {}
	local depth = 0
	local current = {}

	for i = 1, #list do
		local char = list:sub(i, i)

		if char == "(" then
			depth = depth + 1
		elseif char == ")" then
			depth = depth - 1
		end

		if char == "," and depth == 0 then
			table.insert(parts, table.concat(current))
			current = {}
		else
			table.insert(current, char)
		end
	end

	table.insert(parts, table.concat(current))

	return parts
end

--- Is this a bare column reference rather than an expression?
---@param item string
---@return string|nil name
local function bare_column(item)
	local text = vim.trim(item)

	-- An alias means the rendered header no longer names the column, so we
	-- cannot map a grid column back to a real one.
	if text:lower():match("%f[%w]as%f[%W]") or text:match("[%(%)%+%*/%-]") or text:match("::") then
		return nil
	end

	local name = text:match("^[%w_]+$") or text:match("^[%w_]+%.([%w_]+)$")

	return name
end

---@class Dbab.Editability
---@field editable boolean
---@field reason string|nil Why not, when not editable
---@field table_name string|nil
---@field schema string|nil
---@field columns string[]|nil Selected column names, or nil for `SELECT *`
---@field star boolean Whether the select list was `*`

--- Analyse a query for write-back provenance.
---@param query string
---@return Dbab.Editability
function M.analyze(query)
	if query == nil or vim.trim(query) == "" then
		return { editable = false, reason = "no query", star = false }
	end

	local sql = normalize(query)
	-- Keyword matching happens against a lowered copy; every identifier is taken
	-- from `sql` at the same offsets, so its case survives.
	local lower = sql:lower()

	-- More than one statement: we would not know which produced the grid.
	if sql:find(";") then
		return { editable = false, reason = "multiple statements", star = false }
	end

	if not lower:match("^select%f[%W]") then
		return { editable = false, reason = "not a SELECT", star = false }
	end

	for _, rule in ipairs(DISQUALIFIERS) do
		if lower:match(rule.pattern) then
			return { editable = false, reason = rule.reason, star = false }
		end
	end

	local _, select_start = lower:find("^select%s+")
	local from_start, from_end = nil, nil
	if select_start then
		from_start, from_end = lower:find("%s+from%s+", select_start)
	end

	if not select_start or not from_start then
		return { editable = false, reason = "no FROM clause", star = false }
	end

	local select_list = sql:sub(select_start + 1, from_start - 1)
	local from_rest = sql:sub(from_end + 1)
	local select_lower = select_list:lower()

	for _, fn in ipairs(AGGREGATES) do
		if select_lower:match("%f[%w]" .. fn .. "%s*%(") then
			return { editable = false, reason = "query aggregates rows", star = false }
		end
	end

	-- A subquery in the FROM clause has no table to write to.
	if from_rest:match("^%(") then
		return { editable = false, reason = "FROM is a subquery", star = false }
	end

	-- Everything after the table name must be a clause we can live with; a comma
	-- would be an old-style join.
	local table_ref = from_rest:match("^([^%s]+)")
	if not table_ref or table_ref:find(",") or from_rest:match("^[^%s]+%s*,") then
		return { editable = false, reason = "query joins tables", star = false }
	end

	local tail = from_rest:sub(#table_ref + 1)
	local tail_lower = tail:lower()

	-- A table alias is harmless for identifying the table, and `bare_column`
	-- already reduces `t.name` to `name`.
	local first = tail_lower:match("^%s+([%w_]+)")
	local KEEP = { where = true, order = true, limit = true, offset = true, fetch = true, ["for"] = true, group = true }
	if first and not KEEP[first] then
		tail = tail:gsub("^%s+[%w_]+", "", 1)
		tail_lower = tail:lower()
	end

	if tail_lower:match("%f[%w]join%f[%W]") then
		return { editable = false, reason = "query joins tables", star = false }
	end

	local schema, table_name = table_ref:match("^([%w_]+)%.([%w_]+)$")
	if not table_name then
		table_name = table_ref:match("^[%w_]+$")
	end

	if not table_name then
		return { editable = false, reason = "cannot identify the table", star = false }
	end

	if vim.trim(select_list) == "*" then
		return { editable = true, table_name = table_name, schema = schema, star = true }
	end

	local columns = {}
	for _, item in ipairs(split_columns(select_list)) do
		local name = bare_column(item)
		if not name then
			return { editable = false, reason = "select list is not plain columns", star = false }
		end
		table.insert(columns, name)
	end

	if #columns == 0 then
		return { editable = false, reason = "no columns selected", star = false }
	end

	return { editable = true, table_name = table_name, schema = schema, columns = columns, star = false }
end

--- Which of a table's columns form its primary key, and are they all on screen?
---@param analysis Dbab.Editability
---@param table_columns Dbab.Column[] From `core/schema`
---@param grid_columns string[] Column names as rendered
---@return string[]|nil keys, string|nil reason
function M.resolve_keys(analysis, table_columns, grid_columns)
	if not analysis.editable then
		return nil, analysis.reason
	end

	local keys = {}
	for _, col in ipairs(table_columns or {}) do
		if col.is_primary then
			table.insert(keys, col.name)
		end
	end

	if #keys == 0 then
		return nil, "table has no primary key"
	end

	local present = {}
	for _, name in ipairs(grid_columns or {}) do
		present[name:lower()] = true
	end

	for _, key in ipairs(keys) do
		if not present[key:lower()] then
			-- Selecting the key transparently would mean hiding it again at render
			-- time; refusing is the honest answer for now.
			return nil, ("primary key %q is not in the result"):format(key)
		end
	end

	return keys, nil
end

return M
