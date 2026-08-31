---@class Dbab.Selection
local M = {}

--- Normalize a raw visual range into ordered, 0-indexed coordinates.
--- Positions are 1-indexed rows and 1-indexed columns (as returned by |getpos()|).
---@param srow number Start row (1-indexed)
---@param scol number Start column (1-indexed)
---@param erow number End row (1-indexed)
---@param ecol number End column (1-indexed)
---@return number start_row 0-indexed start row
---@return number start_col 0-indexed start column
---@return number end_row 0-indexed end row
---@return number end_col 0-indexed end column
function M.normalize(srow, scol, erow, ecol)
	if srow > erow or (srow == erow and scol > ecol) then
		srow, scol, erow, ecol = erow, ecol, srow, scol
	end
	return srow - 1, scol - 1, erow - 1, ecol
end

--- Extract the text covered by a visual selection from a list of buffer lines.
---@param lines string[] Buffer lines
---@param srow number Start row (1-indexed)
---@param scol number Start column (1-indexed)
---@param erow number End row (1-indexed)
---@param ecol number End column (1-indexed)
---@param mode string Visual mode: "v" (charwise), "V" (linewise) or "\22" (blockwise)
---@return string
function M.extract(lines, srow, scol, erow, ecol, mode)
	local start_row, start_col, end_row, end_col = M.normalize(srow, scol, erow, ecol)

	local selected = {}
	for row = start_row, end_row do
		local line = lines[row + 1]
		if line == nil then
			break
		end

		if mode == "V" then
			table.insert(selected, line)
		elseif mode == "\22" then
			local from = math.min(start_col, end_col)
			local to = math.max(start_col, end_col)
			table.insert(selected, line:sub(from + 1, to))
		else
			local from = (row == start_row) and start_col or 0
			local to = (row == end_row) and end_col or #line
			table.insert(selected, line:sub(from + 1, to))
		end
	end

	return table.concat(selected, "\n")
end

--- Get the text currently selected in visual mode.
--- Must be called while still in visual mode (e.g. from a visual-mode keymap callback).
---@param buf number|nil Buffer handle, defaults to the current buffer
---@return string
function M.get_visual(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(buf) then
		return ""
	end

	local mode = vim.fn.mode()
	if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
		-- Selection already ended: fall back to the last visual marks.
		local sm = vim.fn.getpos("'<")
		local em = vim.fn.getpos("'>")
		mode = vim.fn.visualmode()
		if mode == "" then
			return ""
		end
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		return M.extract(lines, sm[2], sm[3], em[2], em[3], mode)
	end

	local anchor = vim.fn.getpos("v")
	local cursor = vim.fn.getpos(".")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	return M.extract(lines, anchor[2], anchor[3], cursor[2], cursor[3], mode)
end

--- Leave visual mode, restoring normal mode.
function M.exit_visual()
	local keys = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
	vim.api.nvim_feedkeys(keys, "nx", false)
end

return M
