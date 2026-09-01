local config = require("dbab.config")

--- Uppercasing SQL keywords in the query editor.
---
--- Driven by the `sql` treesitter grammar rather than a word list: the grammar
--- already distinguishes `keyword_*` nodes from `identifier`, `literal` and
--- `comment`, so a column called `order`, a string containing "select" and a
--- commented-out clause are all left alone for free.
---@class Dbab.Keywords
local M = {}

--- Enough to be useful when no `sql` parser is installed. Only applied outside
--- strings and comments, which are masked first.
local FALLBACK_KEYWORDS = {
	"select",
	"from",
	"where",
	"insert",
	"into",
	"values",
	"update",
	"set",
	"delete",
	"create",
	"alter",
	"drop",
	"table",
	"view",
	"index",
	"join",
	"inner",
	"left",
	"right",
	"full",
	"outer",
	"cross",
	"on",
	"group",
	"order",
	"by",
	"having",
	"limit",
	"offset",
	"union",
	"all",
	"distinct",
	"as",
	"and",
	"or",
	"not",
	"null",
	"is",
	"in",
	"like",
	"between",
	"exists",
	"case",
	"when",
	"then",
	"else",
	"end",
	"asc",
	"desc",
	"with",
	"returning",
	"primary",
	"key",
	"foreign",
	"references",
	"default",
	"constraint",
	"unique",
	"add",
	"column",
	"if",
}

---@return boolean
local function enabled()
	local cfg = config.get()
	local editor = cfg and cfg.editor or {}

	return editor.upper_keywords ~= false
end

--- Keyword ranges according to the grammar.
---@param buf number
---@return table<number, {from: number, to: number}[]>|nil By 0-indexed line
local function treesitter_ranges(buf)
	local ok, parser = pcall(vim.treesitter.get_parser, buf, "sql")
	if not ok or not parser then
		return nil
	end

	local parsed = parser:parse()
	if not parsed or not parsed[1] then
		return nil
	end

	local by_line = {}

	---@param node TSNode
	local function walk(node)
		if node:type():match("^keyword_") then
			local start_row, start_col, end_row, end_col = node:range()

			-- A keyword never spans lines; anything that claims to is not one.
			if start_row == end_row then
				by_line[start_row] = by_line[start_row] or {}
				table.insert(by_line[start_row], { from = start_col, to = end_col })
			end
		end

		for child in node:iter_children() do
			walk(child)
		end
	end

	walk(parsed[1]:root())

	return by_line
end

--- Blank out the parts of a line that must never be touched, so a plain word
--- match cannot reach inside them.
---@param line string
---@return string masked
local function mask(line)
	local masked = line:gsub("%-%-.*$", function(m)
		return string.rep("\0", #m)
	end)

	for _, quote in ipairs({ "'", '"', "`" }) do
		masked = masked:gsub(quote .. "[^" .. quote .. "]*" .. quote, function(m)
			return string.rep("\0", #m)
		end)
	end

	return masked
end

--- Keyword ranges without a parser.
---@param buf number
---@return table<number, {from: number, to: number}[]>
local function fallback_ranges(buf)
	local lookup = {}
	for _, word in ipairs(FALLBACK_KEYWORDS) do
		lookup[word] = true
	end

	local by_line = {}

	for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		local masked = mask(line)
		local init = 1

		while true do
			local from, to = masked:find("[%a_][%w_]*", init)
			if not from then
				break
			end

			if lookup[masked:sub(from, to):lower()] then
				by_line[row - 1] = by_line[row - 1] or {}
				table.insert(by_line[row - 1], { from = from - 1, to = to })
			end

			init = to + 1
		end
	end

	return by_line
end

--- Uppercase every SQL keyword in a buffer, leaving everything else alone.
---@param buf number
---@return boolean changed
function M.uppercase(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
		return false
	end

	local by_line = treesitter_ranges(buf) or fallback_ranges(buf)
	local changed = false

	for row, ranges in pairs(by_line) do
		local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]

		if line then
			-- Right to left, so an earlier range's offsets stay valid.
			table.sort(ranges, function(a, b)
				return a.from > b.from
			end)

			local updated = line
			for _, range in ipairs(ranges) do
				local word = updated:sub(range.from + 1, range.to)
				local upper = word:upper()

				if word ~= upper then
					updated = updated:sub(1, range.from) .. upper .. updated:sub(range.to + 1)
				end
			end

			-- Only write when something actually changed: an untouched line must
			-- not gain an undo entry or mark the buffer modified.
			if updated ~= line then
				vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { updated })
				changed = true
			end
		end
	end

	return changed
end

--- Uppercase keywords whenever insert mode is left in this buffer.
---@param buf number
function M.attach(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local group = vim.api.nvim_create_augroup(("DbabKeywords%d"):format(buf), { clear = true })

	vim.api.nvim_create_autocmd("InsertLeave", {
		group = group,
		buffer = buf,
		callback = function()
			if not enabled() then
				return
			end

			-- Uppercasing never changes the byte length, so the cursor stays put.
			M.uppercase(buf)
		end,
	})
end

return M
