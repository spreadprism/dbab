local parser = require("dbab.utils.parser")
local config = require("dbab.config")
local icons = require("dbab.ui.icons")
local sticky = require("dbab.ui.sticky")

local M = {}

local workbench

function M.setup(workbench_ref)
	workbench = workbench_ref
end

-- Result state lives on the workbench instance so two workbenches keep their
-- own last result; these names are proxied for the modules that read them.
local RESULT_FIELDS = {
	last_result = true,
	last_query = true,
	last_duration = true,
	last_conn_name = true,
	last_timestamp = true,
	last_result_width = true,
}

setmetatable(M, {
	__index = function(_, k)
		if RESULT_FIELDS[k] then
			return workbench._state().result[k]
		end
	end,
	__newindex = function(t, k, v)
		if RESULT_FIELDS[k] then
			workbench._state().result[k] = v
			return
		end
		rawset(t, k, v)
	end,
})

---@param result Dbab.QueryResult
---@param widths number[]
---@return string[] lines
---@return boolean has_header
---@return {from: number, to: number}[][] spans Per line, per column, in bytes
local function render_result_lines(result, widths)
	local lines = {}
	local spans = {}
	local has_header = #result.columns > 0

	if has_header then
		local line, header_spans = parser.render_row(result.columns, widths)
		table.insert(lines, line)
		table.insert(spans, header_spans)
	end

	for _, row in ipairs(result.rows) do
		local line, row_spans = parser.render_row(row, widths)
		table.insert(lines, line)
		table.insert(spans, row_spans)
	end

	return lines, has_header, spans
end

---@param cell string
---@return string
local function detect_cell_hl(cell)
	-- Only a real null is DbabNull. With a sentinel in play the four-character
	-- string 'NULL' is a distinct value, and it must not look like one.
	if cell == nil or cell == vim.NIL then
		return "DbabNull"
	end

	if type(cell) ~= "string" then
		cell = tostring(cell)
	end

	if cell == "" then
		return "DbabString"
	elseif cell:match("^%-?%d+%.?%d*$") then
		return "DbabNumber"
	elseif cell:match("^[Tt]rue$") or cell:match("^[Ff]alse$") or cell == "t" or cell == "f" then
		return "DbabBoolean"
	elseif cell:match("^%d%d%d%d%-%d%d%-%d%d") then
		return "DbabDateTime"
	elseif cell:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
		return "DbabUuid"
	elseif cell:match("^[%[{]") then
		return "DbabJson"
	else
		return "DbabString"
	end
end

---@param bufnr number
---@param result Dbab.QueryResult
---@param widths number[]
---@param has_header boolean
---@param spans {from: number, to: number}[][] Recorded at render time
local function apply_highlights(bufnr, result, widths, has_header, spans)
	local ns = vim.api.nvim_create_namespace("dbab_result")
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local header_offset = has_header and 1 or 0
	local total_lines = #result.rows + header_offset

	if has_header then
		vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, { end_row = 1, hl_group = "DbabHeader" })
	end

	for line_num = header_offset, total_lines - 1 do
		local row_idx = line_num - header_offset + 1
		local row_hl = row_idx % 2 == 1 and "DbabRowOdd" or "DbabRowEven"
		vim.api.nvim_buf_set_extmark(bufnr, ns, line_num, 0, { end_row = line_num + 1, hl_group = row_hl })
	end

	-- Dim the separators. Their offsets are known from the spans, so the line is
	-- never re-parsed -- a value may itself contain a pipe, which is exactly why
	-- splitting the rendered text is forbidden.
	for line_num = 0, #spans - 1 do
		local line_spans = spans[line_num + 1]
		for col_idx = 1, #line_spans - 1 do
			local sep = line_spans[col_idx + 1].from - 1 - #parser.SEPARATOR
			vim.api.nvim_buf_set_extmark(bufnr, ns, line_num, sep, {
				end_col = sep + #parser.SEPARATOR,
				hl_group = "DbabSeparator",
			})
		end
	end

	for row_idx, row in ipairs(result.rows) do
		local line_num = row_idx - 1 + header_offset
		local row_spans = spans[line_num + 1] or {}

		for col_idx, cell in ipairs(row) do
			local span = row_spans[col_idx]
			if span then
				vim.api.nvim_buf_set_extmark(bufnr, ns, line_num, span.from, {
					end_col = span.to,
					hl_group = detect_cell_hl(cell),
				})
			end
		end
	end
end

--- Dialect of the active connection, so the parser does not have to guess the
--- output format from the text alone.
---@return string|nil
local function active_db_type()
	local connection = require("dbab.core.connection")
	local _, url = workbench.get_active_connection_context()
	if not url then
		return nil
	end

	local ok, db_type = pcall(connection.parse_type, url)
	return ok and db_type or nil
end

---@param raw string
---@return boolean
local function is_error_result(raw)
	return require("dbab.core.executor").is_error(raw)
end

---@param raw string
---@return string[] lines, table[] highlights
local function format_error(raw)
	local lines = {}
	local highlights = {}

	table.insert(lines, "")
	table.insert(lines, " ✗ Query Error")
	table.insert(highlights, { line = 1, hl = "ErrorMsg", col_start = 0, col_end = -1 })
	table.insert(lines, "")

	local raw_lines = vim.split(raw, "\n")
	local found_content = false

	for _, line in ipairs(raw_lines) do
		if line ~= "" then
			if line:match("^ERROR:") then
				local msg = line:match("^ERROR:%s*(.+)") or line
				table.insert(lines, "   " .. msg)
				table.insert(highlights, { line = #lines - 1, hl = "Normal", col_start = 0, col_end = -1 })
				found_content = true
			elseif line:match("^LINE %d+:") then
				table.insert(lines, "")
				table.insert(lines, "   → " .. line)
				table.insert(highlights, { line = #lines - 1, hl = "WarningMsg", col_start = 0, col_end = -1 })
				found_content = true
			elseif line:match("^%s*%^%s*$") then
				table.insert(lines, "     " .. line)
				table.insert(highlights, { line = #lines - 1, hl = "Comment", col_start = 0, col_end = -1 })
				found_content = true
			elseif found_content then
				table.insert(lines, "   " .. line)
				table.insert(highlights, { line = #lines - 1, hl = "Comment", col_start = 0, col_end = -1 })
			end
		end
	end

	if not found_content then
		for _, line in ipairs(raw_lines) do
			if line ~= "" then
				table.insert(lines, "   " .. line)
				table.insert(highlights, { line = #lines - 1, hl = "Normal", col_start = 0, col_end = -1 })
			end
		end
	end

	table.insert(lines, "")

	return lines, highlights
end

---@param raw string
---@return boolean, string|nil verb, number|nil count
local function parse_mutation_result(raw)
	local line = vim.trim(raw)

	local update_count = line:match("^UPDATE%s+(%d+)")
	if update_count then
		return true, "UPDATE", tonumber(update_count)
	end

	local delete_count = line:match("^DELETE%s+(%d+)")
	if delete_count then
		return true, "DELETE", tonumber(delete_count)
	end

	local insert_count = line:match("^INSERT%s+%d+%s+(%d+)")
	if insert_count then
		return true, "INSERT", tonumber(insert_count)
	end

	if line:match("^CREATE") then
		return true, "CREATE", nil
	end
	if line:match("^DROP") then
		return true, "DROP", nil
	end
	if line:match("^ALTER") then
		return true, "ALTER", nil
	end
	if line:match("^TRUNCATE") then
		return true, "TRUNCATE", nil
	end

	return false, nil, nil
end

---@param verb string
---@param count number|nil
---@return string[] lines, table[] highlights
local function format_mutation_result(verb, count)
	local lines = {}
	local highlights = {}

	local verb_config = {
		UPDATE = { icon = icons.mut_update, hl = "DbabHistoryUpdate", label = "updated" },
		DELETE = { icon = icons.mut_delete, hl = "DbabHistoryDelete", label = "deleted" },
		INSERT = { icon = icons.mut_insert, hl = "DbabHistoryInsert", label = "inserted" },
		CREATE = { icon = icons.mut_create, hl = "DbabHistoryCreate", label = "created" },
		DROP = { icon = icons.mut_delete, hl = "DbabHistoryDelete", label = "dropped" },
		ALTER = { icon = icons.mut_update, hl = "DbabHistoryAlter", label = "altered" },
		TRUNCATE = { icon = icons.mut_delete, hl = "DbabHistoryTruncate", label = "truncated" },
	}

	local cfg = verb_config[verb] or { icon = "✓", hl = "String", label = "completed" }

	table.insert(lines, "")

	local result_line
	if count then
		local row_word = count == 1 and "row" or "rows"
		result_line = string.format(" %s %d %s %s", cfg.icon, count, row_word, cfg.label)
	else
		result_line = string.format(" %s %s successful", cfg.icon, verb)
	end
	table.insert(lines, result_line)
	table.insert(highlights, { line = 1, hl = cfg.hl, col_start = 0, col_end = -1 })

	table.insert(lines, "")

	return lines, highlights
end

---@param raw string
---@param elapsed number
function M.show_result(raw, elapsed)
	if not workbench.result_buf or not vim.api.nvim_buf_is_valid(workbench.result_buf) then
		return
	end

	vim.bo[workbench.result_buf].modifiable = true

	-- Cleared up front: every branch below that is not a table grid has no
	-- header line for the float to stand in for.
	sticky.set_header(workbench._state(), nil)

	if is_error_result(raw) then
		local lines, highlights = format_error(raw)

		vim.api.nvim_buf_set_lines(workbench.result_buf, 0, -1, false, lines)
		vim.bo[workbench.result_buf].modifiable = false

		if workbench.result_win and vim.api.nvim_win_is_valid(workbench.result_win) then
			vim.wo[workbench.result_win].number = false
			vim.wo[workbench.result_win].relativenumber = false
		end

		local ns = vim.api.nvim_create_namespace("dbab_result")
		vim.api.nvim_buf_clear_namespace(workbench.result_buf, ns, 0, -1)
		for _, hl in ipairs(highlights) do
			vim.api.nvim_buf_set_extmark(
				workbench.result_buf,
				ns,
				hl.line,
				hl.col_start,
				{ end_col = hl.col_end, hl_group = hl.hl }
			)
		end

		vim.notify("[dbab] Query error", vim.log.levels.ERROR)
		return
	end

	local is_mutation, verb, count = parse_mutation_result(raw)
	if is_mutation and verb then
		local lines, highlights = format_mutation_result(verb, count)

		vim.api.nvim_buf_set_lines(workbench.result_buf, 0, -1, false, lines)
		vim.bo[workbench.result_buf].modifiable = false

		if workbench.result_win and vim.api.nvim_win_is_valid(workbench.result_win) then
			vim.wo[workbench.result_win].number = false
			vim.wo[workbench.result_win].relativenumber = false
		end

		local ns = vim.api.nvim_create_namespace("dbab_result")
		vim.api.nvim_buf_clear_namespace(workbench.result_buf, ns, 0, -1)
		for _, hl in ipairs(highlights) do
			vim.api.nvim_buf_set_extmark(
				workbench.result_buf,
				ns,
				hl.line,
				hl.col_start,
				{ end_col = hl.col_end, hl_group = hl.hl }
			)
		end

		M.last_result = { columns = {}, rows = {}, row_count = count or 0, raw = raw }
		require("dbab.ui.winbar").refresh_result()

		local status_msg = count and string.format(" %s: %d rows (%.1fms) ", verb, count, elapsed)
			or string.format(" %s successful (%.1fms) ", verb, elapsed)
		vim.notify(status_msg, vim.log.levels.INFO)
		return
	end

	local cfg = config.get()

	if workbench.result_win and vim.api.nvim_win_is_valid(workbench.result_win) then
		vim.wo[workbench.result_win].number = cfg.result.show_line_number
	end

	local result_style = cfg.result.style or "table"
	local result = parser.parse(raw, result_style, active_db_type())
	M.last_result = result

	pcall(vim.treesitter.stop, workbench.result_buf)
	vim.bo[workbench.result_buf].filetype = ""

	if result.row_count == 0 then
		vim.api.nvim_buf_set_lines(workbench.result_buf, 0, -1, false, { "No results returned" })
		vim.bo[workbench.result_buf].modifiable = false
		return
	end

	if result_style == "raw" then
		local raw_lines = vim.split(result.raw, "\n")
		vim.api.nvim_buf_set_lines(workbench.result_buf, 0, -1, false, raw_lines)
		vim.bo[workbench.result_buf].modifiable = false
		require("dbab.ui.winbar").refresh_result()
		return
	end

	if result_style == "json" then
		local json_lines = vim.split(result.raw, "\n")
		vim.api.nvim_buf_set_lines(workbench.result_buf, 0, -1, false, json_lines)
		vim.bo[workbench.result_buf].modifiable = false
		local ok = pcall(vim.treesitter.start, workbench.result_buf, "json")
		if not ok then
			vim.bo[workbench.result_buf].filetype = "json"
		end
		require("dbab.ui.winbar").refresh_result()
		return
	end

	if result_style == "vertical" then
		local vert_lines = vim.split(result.raw, "\n")
		vim.api.nvim_buf_set_lines(workbench.result_buf, 0, -1, false, vert_lines)
		vim.bo[workbench.result_buf].modifiable = false

		local ns = vim.api.nvim_create_namespace("dbab_result")
		vim.api.nvim_buf_clear_namespace(workbench.result_buf, ns, 0, -1)

		for i, line in ipairs(vert_lines) do
			local ln = i - 1
			if line:match("^%-%[ RECORD %d+") then
				vim.api.nvim_buf_set_extmark(workbench.result_buf, ns, ln, 0, { end_row = ln + 1, hl_group = "DbabHeader" })
			else
				local sep = line:find(" | ")
				if sep then
					local col_name = vim.trim(line:sub(1, sep - 1))
					local col_start = line:find(col_name, 1, true)
					vim.api.nvim_buf_set_extmark(
						workbench.result_buf,
						ns,
						ln,
						col_start - 1,
						{ end_col = col_start - 1 + #col_name, hl_group = "DbabKey" }
					)

					vim.api.nvim_buf_set_extmark(
						workbench.result_buf,
						ns,
						ln,
						sep - 1,
						{ end_col = sep + 2, hl_group = "DbabBorder" }
					)

					local value = vim.trim(line:sub(sep + 3))
					local value_start = sep + 2
					local hl_group = detect_cell_hl(value)
					vim.api.nvim_buf_set_extmark(
						workbench.result_buf,
						ns,
						ln,
						value_start,
						{ end_col = value_start + #value, hl_group = hl_group }
					)
				end
			end
		end

		require("dbab.ui.winbar").refresh_result()
		return
	end

	if result_style == "markdown" then
		local md_lines = vim.split(result.raw, "\n")
		vim.api.nvim_buf_set_lines(workbench.result_buf, 0, -1, false, md_lines)
		vim.bo[workbench.result_buf].modifiable = false
		local ok = pcall(vim.treesitter.start, workbench.result_buf, "markdown")
		if not ok then
			vim.bo[workbench.result_buf].filetype = "markdown"
		end
		require("dbab.ui.winbar").refresh_result()
		return
	end

	local widths = parser.calculate_column_widths(result)
	local lines, has_header, spans = render_result_lines(result, widths)

	local grid_width = 0
	for _, w in ipairs(widths) do
		grid_width = grid_width + w + 2 + #parser.SEPARATOR
	end
	-- No trailing separator after the last column.
	M.last_result_width = math.max(grid_width - #parser.SEPARATOR, 0)

	vim.api.nvim_buf_set_lines(workbench.result_buf, 0, -1, false, lines)
	vim.bo[workbench.result_buf].modifiable = false

	apply_highlights(workbench.result_buf, result, widths, has_header, spans)

	-- A new result changes the header text, and the float is not otherwise told.
	sticky.set_header(workbench._state(), has_header and lines[1] or nil)

	require("dbab.ui.winbar").refresh_result()

	local status = string.format(" Result: %d rows (%.1fms) ", result.row_count, elapsed)
	vim.notify(status, vim.log.levels.INFO)

	if workbench.result_win and vim.api.nvim_win_is_valid(workbench.result_win) then
		-- Cursor is placed on the first data row either way; focus only follows
		-- it when the user asked for that.
		pcall(vim.api.nvim_win_set_cursor, workbench.result_win, { 2, 0 })

		if cfg.result.focus_on_execute then
			vim.api.nvim_set_current_win(workbench.result_win)
			vim.cmd("stopinsert")
		end

		sticky.follow(workbench._state(), workbench.result_win)
	end
end

function M.yank_current_row()
	if not M.last_result or not workbench.result_win then
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(workbench.result_win)
	local row_idx = cursor[1] - 1

	if row_idx < 1 or row_idx > #M.last_result.rows then
		vim.notify("[dbab] No data row selected", vim.log.levels.WARN)
		return
	end

	local row = M.last_result.rows[row_idx]
	local obj = {}
	for i, col in ipairs(M.last_result.columns) do
		obj[col] = row[i]
	end

	local json = vim.fn.json_encode(obj)
	vim.fn.setreg("+", json)
	vim.fn.setreg('"', json)
	vim.notify("[dbab] Row copied as JSON", vim.log.levels.INFO)
end

function M.yank_all_rows()
	if not M.last_result then
		return
	end

	local arr = {}
	for _, row in ipairs(M.last_result.rows) do
		local obj = {}
		for i, col in ipairs(M.last_result.columns) do
			obj[col] = row[i]
		end
		table.insert(arr, obj)
	end

	local json = vim.fn.json_encode(arr)
	vim.fn.setreg("+", json)
	vim.fn.setreg('"', json)
	vim.notify("[dbab] All rows copied as JSON", vim.log.levels.INFO)
end

return M
