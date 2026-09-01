--- See lua/dbab/types.lua for type definitions (Dbab.QueryResult)

local M = {}

--- The column separator.
---
--- ASCII, not a box-drawing character: `|` is one byte and one display column,
--- so for ASCII data a byte offset equals a screen column. `\u{2502}` is three
--- bytes for one column, which forces every offset calculation to carry two
--- measures from the very first character. Keeping it ASCII confines that
--- divergence to non-ASCII *data* (see `render_row`), and the result survives
--- being yanked into a terminal or a commit message.
M.SEPARATOR = "|"

--- Must match `core/adapter.lua`'s `NULL_SENTINEL`.
M.NULL_SENTINEL = "\\N"

--- How a value is printed.
---
--- `vim.NIL` rather than a Lua `nil`: a real nil leaves a hole in the row array,
--- so `#row` stops short and every cell after a null falls out of alignment
--- with `columns`.
---@param value any
---@return string
function M.display(value)
	if value == nil or value == vim.NIL then
		return "NULL"
	end

	return tostring(value)
end

--- Turn a client's null sentinel back into a value.
---
--- `vim.NIL` and not `nil`: a real nil leaves a hole in the row array, so `#row`
--- stops short and every cell after a null falls out of alignment with
--- `columns`. That bites the moment a nullable column appears anywhere but last.
---@param cell string
---@param db_type? string
---@return string|userdata
function M.to_value(cell, db_type)
	if cell == M.NULL_SENTINEL then
		return vim.NIL
	end

	-- MySQL cannot be given a sentinel; batch mode prints a bare `NULL`, which
	-- is therefore indistinguishable from the four-character string 'NULL'.
	if db_type == "mysql" and cell == "NULL" then
		return vim.NIL
	end

	return cell
end

--- Make a value safe to put in a buffer line.
---
--- `nvim_buf_set_lines` rejects newlines and carriage returns outright, a tab
--- renders as a variable-width jump, and a control character prints as `^X` --
--- two columns for one byte. Any of them desynchronises width from bytes and
--- destroys the grid.
---@param text string
---@return string
function M.sanitize(text)
	text = text:gsub("\r\n", " "):gsub("[\r\n]", " "):gsub("\t", " ")
	text = text:gsub("%c", " ")

	return text
end

--- Render one row, and report where each cell landed.
---
--- Each cell is padded to its column width and carries a space on *both* sides;
--- columns are joined with a single separator and nothing else. The space you
--- see either side of the pipe belongs to the neighbouring cells.
---
--- The spans come back with the line because this is the only place that knows
--- the layout: padding is measured in display cells, while extmarks and
--- `nvim_buf_get_text` are addressed in bytes. Having callers re-derive the
--- geometry is how highlights end up a character off.
---@param cells any[]
---@param widths number[]
---@return string line
---@return {from: number, to: number}[] spans Byte offsets, 0-indexed, `to` exclusive
function M.render_row(cells, widths)
	local out = {}
	local spans = {}
	local bytes = 0

	for index, cell in ipairs(cells) do
		local text = M.sanitize(M.display(cell))
		local pad = math.max((widths[index] or 0) - vim.fn.strdisplaywidth(text), 0)

		-- `to` excludes the padding: the spaces between a short value and the
		-- separator belong to no cell, and a number should not have a
		-- highlighted tail.
		spans[index] = { from = bytes + 1, to = bytes + 1 + #text }

		table.insert(out, (" %s%s "):format(text, string.rep(" ", pad)))
		bytes = bytes + 1 + #text + pad + 1 + #M.SEPARATOR
	end

	return table.concat(out, M.SEPARATOR), spans
end

--- The inverse of the offset walk: which column is a byte column inside?
---@param widths number[]
---@param col number 0-indexed byte column, as `nvim_win_get_cursor` reports it
---@return number|nil index, number|nil from, number|nil to
function M.column_at(widths, col)
	local column = 0

	for index = 1, #widths do
		local from = column + 1
		local to = from + widths[index]

		if col < to + 1 then
			return index, from, to
		end

		column = to + 1 + #M.SEPARATOR
	end

	return nil
end

---@param raw string Raw output from database
---@param style? Dbab.ResultStyle "table" (default), "json", "raw", "vertical", "markdown"
---@param db_type? string Dialect hint ("mysql", "postgres", "sqlite")
---@return Dbab.QueryResult
function M.parse(raw, style, db_type)
	local result = {
		columns = {},
		rows = {},
		row_count = 0,
		raw = raw,
	}

	if style == "raw" then
		result.columns = { "raw" }
		for _, line in ipairs(vim.split(raw, "\n")) do
			table.insert(result.rows, { line })
		end
		result.row_count = #result.rows
		return result
	end

	local table_result = M.parse_table(raw, db_type)

	if style == "json" then
		local json_data = {}
		for _, row in ipairs(table_result.rows) do
			local item = {}
			for i, col in ipairs(table_result.columns) do
				-- vim.NIL encodes as JSON null, which is what it means.
				item[col] = row[i] ~= nil and row[i] or vim.NIL
			end
			table.insert(json_data, item)
		end

		local lines = { "[" }
		for idx, item in ipairs(json_data) do
			local ok, item_str = pcall(vim.json.encode, item)
			if ok then
				local suffix = idx < #json_data and "," or ""
				table.insert(lines, "  " .. item_str .. suffix)
			end
		end
		table.insert(lines, "]")

		local pretty = table.concat(lines, "\n")
		result.raw = pretty
		result.columns = table_result.columns
		for _, line in ipairs(lines) do
			table.insert(result.rows, { line })
		end
		result.row_count = #json_data
		return result
	end

	if style == "vertical" then
		local col_width = 0
		for _, col in ipairs(table_result.columns) do
			col_width = math.max(col_width, #col)
		end

		local lines = {}
		for idx, row in ipairs(table_result.rows) do
			table.insert(lines, string.format("-[ RECORD %d ]%s", idx, string.rep("-", 16)))
			for i, col in ipairs(table_result.columns) do
				local padded = col .. string.rep(" ", col_width - #col)
				table.insert(lines, string.format("%s | %s", padded, M.display(row[i])))
			end
		end

		result.raw = table.concat(lines, "\n")
		result.columns = table_result.columns
		for _, line in ipairs(lines) do
			table.insert(result.rows, { line })
		end
		result.row_count = #table_result.rows
		return result
	end

	if style == "markdown" then
		local widths = M.calculate_column_widths(table_result)

		local lines = {}
		local header_parts = {}
		for i, col in ipairs(table_result.columns) do
			table.insert(header_parts, " " .. col .. string.rep(" ", widths[i] - #col) .. " ")
		end
		table.insert(lines, "|" .. table.concat(header_parts, "|") .. "|")

		local sep_parts = {}
		for _, w in ipairs(widths) do
			table.insert(sep_parts, string.rep("-", w + 2))
		end
		table.insert(lines, "|" .. table.concat(sep_parts, "|") .. "|")

		for _, row in ipairs(table_result.rows) do
			local row_parts = {}
			for i, cell in ipairs(row) do
				local text = M.display(cell)
				local w = widths[i] or #text
				table.insert(row_parts, " " .. text .. string.rep(" ", w - #text) .. " ")
			end
			table.insert(lines, "|" .. table.concat(row_parts, "|") .. "|")
		end

		result.raw = table.concat(lines, "\n")
		result.columns = table_result.columns
		for _, line in ipairs(lines) do
			table.insert(result.rows, { line })
		end
		result.row_count = #table_result.rows
		return result
	end

	return table_result
end

---@param raw string
---@param db_type? string Dialect hint ("mysql", "postgres", "sqlite")
---@return Dbab.QueryResult
function M.parse_table(raw, db_type)
	local lines = vim.split(raw, "\n")

	lines = vim.tbl_filter(function(line)
		return not line:match("^mysql: %[Warning%]")
	end, lines)

	local result = {
		columns = {},
		rows = {},
		row_count = 0,
		raw = raw,
	}

	if #lines == 0 then
		result.columns = { "result" }
		return result
	end

	local header_line = lines[1]
	local separator_line = lines[2] or ""

	-- MySQL batch output is tab separated, so a tab is normally enough to
	-- recognise it. A single-column result (`SELECT COUNT(*)`, `SHOW DATABASES`)
	-- has no tab to be recognised by, and would otherwise fall through to the
	-- "unstructured text" branch below -- which turns the header into a data row
	-- and names the column "result". So when the dialect is known, trust it.
	local is_tab_separated = header_line:find("\t") ~= nil

	if not is_tab_separated and db_type == "mysql" and header_line ~= "" and not separator_line:match("^[%-+]") then
		is_tab_separated = true
	end

	if is_tab_separated then
		result.columns = vim.split(header_line, "\t")

		-- Blank lines are kept: `systemlist` already drops the trailing newline,
		-- so a remaining empty line is a real row whose single column is an
		-- empty string. Skipping them loses the row entirely.
		for i = 2, #lines do
			local line = lines[i]
			do
				local row = vim.split(line, "\t")
				for idx, cell in ipairs(row) do
					row[idx] = M.to_value(cell, db_type)
				end
				table.insert(result.rows, row)
			end
		end
		result.row_count = #result.rows
		return result
	end

	if not separator_line:match("^%-") and not separator_line:match("^%+") then
		-- Unstructured output (notably sqlite3, which prints no header). Still
		-- worth turning the sentinel into a real null so it does not show up as
		-- a literal backslash-N.
		result.columns = { "result" }
		for _, line in ipairs(lines) do
			if line ~= "" then
				table.insert(result.rows, { M.to_value(line, db_type) })
			end
		end
		result.row_count = #result.rows
		return result
	end

	local col_positions = {}
	local pos = 1
	for segment in separator_line:gmatch("[%-]+") do
		local start_pos = separator_line:find(segment, pos, true)
		local end_pos = start_pos + #segment - 1
		table.insert(col_positions, { start = start_pos, finish = end_pos })
		pos = end_pos + 1
	end

	for _, col_pos in ipairs(col_positions) do
		local col_name = header_line:sub(col_pos.start, col_pos.finish)
		col_name = vim.trim(col_name)
		table.insert(result.columns, col_name)
	end

	for i = 3, #lines do
		local line = lines[i]

		if line:match("^%(%d+ rows?%)") then
			local count = line:match("%((%d+) rows?%)")
			result.row_count = tonumber(count) or #result.rows
			break
		end

		if line ~= "" then
			local row = {}
			for _, col_pos in ipairs(col_positions) do
				local cell = ""
				if col_pos.start <= #line then
					cell = line:sub(col_pos.start, math.min(col_pos.finish, #line))
					cell = vim.trim(cell)
				end
				table.insert(row, M.to_value(cell, db_type))
			end
			table.insert(result.rows, row)
		end
	end

	if result.row_count == 0 then
		result.row_count = #result.rows
	end

	return result
end

---@param result Dbab.QueryResult
---@return number[] Column widths
function M.calculate_column_widths(result)
	local widths = {}

	-- Measured in DISPLAY CELLS, not bytes, and through `display` so a header is
	-- measured exactly as it will be printed. `#"Jose\u{301}"` is 5 bytes for 4
	-- columns; pad by byte length and every separator after it shifts left.
	for i, col in ipairs(result.columns) do
		widths[i] = vim.fn.strdisplaywidth(M.sanitize(M.display(col)))
	end

	for _, row in ipairs(result.rows) do
		for i, cell in ipairs(row) do
			widths[i] = math.max(widths[i] or 0, vim.fn.strdisplaywidth(M.sanitize(M.display(cell))))
		end
	end

	return widths
end

return M
