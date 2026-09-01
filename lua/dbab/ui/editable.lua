local provenance = require("dbab.core.provenance")
local dialect = require("dbab.core.dialect")
local parser = require("dbab.utils.parser")
local schema = require("dbab.core.schema")
local executor = require("dbab.core.executor")

--- Editing the result grid in place.
---
--- Two problems make this hard, and everything here is about them:
---   * **provenance** -- which row of which table is this line? (`core/provenance`)
---   * **drift** -- once the user types, the byte offsets recorded at render
---     time no longer describe the text.
---
--- Drift is solved with extmarks. Re-deriving the columns from the text is
--- impossible because a value may contain the separator, so each cell is
--- anchored at render time and Neovim maintains its position through every edit.
---@class Dbab.Editable
local M = {}

--- Cell anchors live in their own namespace: highlights are cleared and rebuilt
--- on every repaint, but anchors must survive until the result is replaced.
local NS_CELL = vim.api.nvim_create_namespace("dbab_cells")

---@class Dbab.EditState
---@field buf number
---@field url string
---@field db_type string
---@field query string
---@field editable boolean
---@field reason string|nil
---@field table_name string|nil
---@field schema string|nil
---@field keys string[]|nil
---@field result Dbab.QueryResult|nil Values as rendered, for comparison
---@field header_offset number 1 when a header line was rendered
---@field anchors number[][]|nil anchors[row][col] = extmark id

---@type table<number, Dbab.EditState>
local states = {}

---@param buf number
---@return Dbab.EditState|nil
function M.state(buf)
	return states[buf]
end

--- The inverse of `parser.display`.
---
--- Two round-trip ambiguities the user cannot otherwise resolve, both of which
--- are documented: the exact unquoted text `NULL` means SQL NULL, so a literal
--- 'NULL' string cannot be typed into the grid; and padding is stripped on read,
--- so a value cannot end in a space.
---@param text string
---@return string|userdata
function M.parse_cell(text)
	local trimmed = vim.trim(text)

	if trimmed == "NULL" then
		return vim.NIL
	end

	return trimmed
end

--- Decide whether a rendered result may be written back to.
---@param query string
---@param url string
---@param db_type string
---@param result Dbab.QueryResult
---@return Dbab.EditState
function M.analyze(query, url, db_type, result)
	local state = {
		url = url,
		db_type = db_type,
		query = query,
		editable = false,
		result = result,
	}

	local analysis = provenance.analyze(query)
	if not analysis.editable then
		state.reason = analysis.reason
		return state
	end

	local table_columns = schema.get_columns(url, analysis.table_name)
	local keys, reason = provenance.resolve_keys(analysis, table_columns, result.columns)

	if not keys then
		state.reason = reason
		return state
	end

	state.editable = true
	state.table_name = analysis.table_name
	state.schema = analysis.schema
	state.keys = keys

	return state
end

--- Anchor every cell so its position survives the user's edits.
---@param buf number
---@param state Dbab.EditState
---@param spans {from: number, to: number}[][] From `parser.render_row`
---@param header_offset number 1 when a header line was rendered
function M.attach(buf, state, spans, header_offset)
	M.detach(buf)

	state.buf = buf
	state.header_offset = header_offset
	states[buf] = state

	if not state.editable then
		return
	end

	local anchors = {}

	for row_idx = 1, #state.result.rows do
		local line = row_idx - 1 + header_offset
		local row_spans = spans[line + 1] or {}
		local row_anchors = {}

		for col_idx = 1, #state.result.columns do
			local span = row_spans[col_idx]
			if span then
				row_anchors[col_idx] = vim.api.nvim_buf_set_extmark(buf, NS_CELL, line, span.from, {
					end_col = span.to,
					-- The start stays put when text is inserted at `from` and the
					-- end moves right as text is inserted before it, so the mark
					-- grows to contain whatever is typed inside the cell while
					-- refusing edits made strictly before it (which belong to the
					-- previous cell's padding or to the separator).
					right_gravity = false,
					end_right_gravity = true,
				})
			end
		end

		anchors[row_idx] = row_anchors
	end

	state.anchors = anchors
end

---@param buf number
function M.detach(buf)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_clear_namespace, buf, NS_CELL, 0, -1)
	end

	states[buf] = nil
end

---@class Dbab.DirtyCell
---@field row number Index into result.rows
---@field column number Index into result.columns
---@field value string|userdata

--- Which cells no longer match what was rendered.
---
--- The buffer is never diffed: each anchor is read back and compared against the
--- original value.
---@param buf number
---@return Dbab.DirtyCell[]
function M.dirty_cells(buf)
	local state = states[buf]
	local changed = {}

	if not state or not state.editable or not state.anchors then
		return changed
	end

	for row_idx, row in ipairs(state.anchors) do
		for col_idx, id in pairs(row) do
			local mark = vim.api.nvim_buf_get_extmark_by_id(buf, NS_CELL, id, { details = true })

			if mark and mark[1] ~= nil and mark[3] and mark[3].end_col then
				local ok, lines = pcall(vim.api.nvim_buf_get_text, buf, mark[1], mark[2], mark[1], mark[3].end_col, {})
				local text = ok and lines[1] or nil

				if text ~= nil then
					local before = parser.display(state.result.rows[row_idx][col_idx])

					if text ~= before then
						table.insert(changed, {
							row = row_idx,
							column = col_idx,
							value = M.parse_cell(text),
						})
					end
				end
			end
		end
	end

	table.sort(changed, function(a, b)
		if a.row ~= b.row then
			return a.row < b.row
		end
		return a.column < b.column
	end)

	return changed
end

--- Has the user changed the shape of the buffer rather than the contents of a
--- cell?
---
--- Deleting or replacing a whole line collapses that row's anchors onto a single
--- point, and adding a line leaves cells with no anchor at all. Either way the
--- geometry no longer describes the text, and generating UPDATEs from it would
--- write empty strings over the row. Refusing and asking for a re-run is the
--- honest answer.
---@param buf number
---@param state Dbab.EditState
---@return string|nil reason
local function structural_edit(buf, state)
	local expected = #state.result.rows + state.header_offset
	if vim.api.nvim_buf_line_count(buf) ~= expected then
		return "lines were added or removed"
	end

	for row_idx, row in ipairs(state.anchors or {}) do
		local collapsed = 0
		local total = 0

		for _, id in pairs(row) do
			total = total + 1
			local mark = vim.api.nvim_buf_get_extmark_by_id(buf, NS_CELL, id, { details = true })
			if not mark or mark[1] == nil then
				return ("row %d lost its anchors"):format(row_idx)
			end
			if mark[3] and mark[3].end_col == mark[2] then
				collapsed = collapsed + 1
			end
		end

		-- One empty cell is a legitimate edit; a whole row of them is not.
		if total > 1 and collapsed == total then
			return ("row %d was replaced rather than edited"):format(row_idx)
		end
	end

	return nil
end

--- Turn dirty cells into one UPDATE per row.
---@param buf number
---@return string[] statements
---@return string|nil err
function M.statements(buf)
	local state = states[buf]
	if not state or not state.editable then
		return {}, state and state.reason or "result is not editable"
	end

	local structural = structural_edit(buf, state)
	if structural then
		return {}, structural .. " -- re-run the query and edit cells in place"
	end

	local dirty = M.dirty_cells(buf)
	if #dirty == 0 then
		return {}, nil
	end

	local column_index = {}
	for idx, name in ipairs(state.result.columns) do
		column_index[name:lower()] = idx
	end

	-- Grouped per row: fewer round trips, and a row edited across three columns
	-- is one logical change.
	local by_row = {}
	local order = {}

	for _, cell in ipairs(dirty) do
		if not by_row[cell.row] then
			by_row[cell.row] = {}
			table.insert(order, cell.row)
		end
		table.insert(by_row[cell.row], cell)
	end

	local statements = {}

	for _, row_idx in ipairs(order) do
		local sets = {}
		for _, cell in ipairs(by_row[row_idx]) do
			table.insert(sets, { column = state.result.columns[cell.column], value = cell.value })
		end

		local wheres = {}
		for _, key in ipairs(state.keys) do
			local idx = column_index[key:lower()]
			if not idx then
				return {}, ("primary key %q is not in the result"):format(key)
			end

			-- From the ORIGINAL values, never the edited buffer: the user may have
			-- edited the key column itself, and the row to find is the one
			-- identified by its old value.
			table.insert(wheres, { column = key, value = state.result.rows[row_idx][idx] })
		end

		table.insert(
			statements,
			dialect.update({
				table_name = state.table_name,
				schema = state.schema,
				sets = sets,
				wheres = wheres,
			}, state.db_type)
		)
	end

	return statements, nil
end

--- Run the statements behind the one-row guard.
---@param buf number
---@param statements string[]
---@return boolean ok
---@return string|nil err
function M.apply(buf, statements)
	local state = states[buf]
	if not state then
		return false, "no edit state"
	end

	local payload = dialect.guard(statements, state.db_type)
	local out = executor.execute(state.url, payload)

	if executor.is_error(out) then
		local first = vim.split(vim.trim(out), "\n")[1]

		-- Each dialect trips its guard in its own idiom; say what it means.
		if
			first:match("expected 1 row")
			or first:match("Subquery returns more than 1 row")
			or first:match("integer overflow")
		then
			return false,
				"the row was not matched exactly once -- it may have changed or been deleted. "
					.. "Nothing was written; re-run the query."
		end

		return false, first
	end

	return true, nil
end

return M
