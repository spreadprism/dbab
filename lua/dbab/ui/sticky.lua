local config = require("dbab.config")

--- Sticky header for the result grid.
---
--- An extmark (and therefore virtual text / virtual lines) belongs to a buffer
--- line and scrolls with it, so it can never be drawn above the top of the
--- window -- which is exactly where a sticky header must live. A floating
--- window with `relative = "win"` and `row = 0` is pinned there by Neovim
--- itself, so that is what we use.
---@class Dbab.Sticky
local M = {}

--- zindex matching nvim-treesitter-context's default so the two do not fight.
local ZINDEX = 20

local AUGROUP = "DbabSticky"

--- Per-workbench float state lives on the instance, so two workbenches do not
--- fight over one float. `wb` is always passed explicitly.
---@param wb table
---@return table
local function st(wb)
	return wb.sticky
end

---@return boolean
local function enabled()
	local cfg = config.get()
	local result_cfg = cfg and cfg.result or {}
	return result_cfg.sticky_header ~= false
end

---@param win number|nil
---@return boolean
local function win_valid(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Scratch buffer backing the float, created lazily.
---@return number
---@param wb table
function M.buffer(wb)
	local s = st(wb)
	if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
		return s.buf
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	-- Nothing here is ever undone: it is rewritten on every scroll event.
	vim.bo[buf].undolevels = -1
	s.buf = buf

	return buf
end

--- Set the header line the float should mirror. `nil` disables the float.
---@param wb table
---@param header string|nil
function M.set_header(wb, header)
	st(wb).header = header
	if header == nil then
		M.hide(wb)
	end
end

---@param wb table
function M.hide(wb)
	local s = st(wb)
	if win_valid(s.win) then
		pcall(vim.api.nvim_win_close, s.win, true)
	end
	s.win = nil
end

--- Show / move / hide the float to match the current scroll position of `win`.
---@param wb table
---@param win number|nil Result window
function M.follow(wb, win)
	local s = st(wb)
	if not enabled() or s.header == nil or not win_valid(win) then
		M.hide(wb)
		return
	end

	-- `w0` is the first line the window shows. Line 1 is the header itself, so
	-- only past it is there anything to stand in for.
	if vim.fn.line("w0", win) <= 1 then
		M.hide(wb)
		return
	end

	local buf = M.buffer(wb)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { s.header })

	-- `textoff` is the width of the number column, signs and folds, so the float
	-- starts where the buffer text starts instead of over the line numbers.
	local info = vim.fn.getwininfo(win)[1]
	local textoff = info and info.textoff or 0
	local width = math.max(vim.api.nvim_win_get_width(win) - textoff, 1)

	local geometry = {
		relative = "win",
		win = win,
		row = 0,
		col = textoff,
		width = width,
		height = 1,
	}

	if win_valid(s.win) then
		-- Moved rather than reopened, so scrolling does not flicker.
		pcall(vim.api.nvim_win_set_config, s.win, geometry)
	else
		local ok, float = pcall(
			vim.api.nvim_open_win,
			buf,
			false,
			vim.tbl_extend("force", geometry, {
				focusable = false,
				style = "minimal",
				-- Opening a window is an event, and this one is scenery: without
				-- this it re-enters the autocommands that called us.
				noautocmd = true,
				zindex = ZINDEX,
			})
		)

		if not ok then
			return
		end

		s.win = float
		vim.wo[float].wrap = false
		vim.wo[float].foldenable = false
		vim.wo[float].cursorline = false
		-- The whole float is the header, so the header colour is its normal.
		vim.wo[float].winhl = "NormalFloat:DbabHeader"
	end

	-- Sync horizontal scroll, or the column names sit over the wrong columns the
	-- moment the grid is wider than the pane. `winsaveview` reports the *current*
	-- window, so it must be taken inside `nvim_win_call` on the source window.
	local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
	pcall(vim.api.nvim_win_call, s.win, function()
		vim.fn.winrestview({ leftcol = view.leftcol })
	end)
end

--- Keep the cursor off the header line: `gg`, a click, or `k` from row 1 should
--- all settle on data.
---@param wb table
---@param win number|nil Result window
function M.skip_header(wb, win)
	if st(wb).header == nil or not win_valid(win) then
		return
	end

	local position = vim.api.nvim_win_get_cursor(win)
	if position[1] > 1 then
		return
	end

	local buf = vim.api.nvim_win_get_buf(win)
	local rows = vim.api.nvim_buf_get_lines(buf, 1, 2, false)

	-- A header with nothing under it keeps the cursor: nowhere else to be.
	if #rows == 0 then
		return
	end

	-- Clamped: the column the cursor was in may be past the end of the line it
	-- lands on, and nvim_win_set_cursor refuses that.
	local col = math.min(position[2], math.max(#rows[1] - 1, 0))
	pcall(vim.api.nvim_win_set_cursor, win, { 2, col })
end

--- Attach the autocommands that drive the float to the result buffer.
---@param wb table Owning workbench
---@param buf number Result buffer
---@param get_win fun():number|nil Resolver for the current result window
function M.attach(wb, buf, get_win)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local group = vim.api.nvim_create_augroup(("%s%d"):format(AUGROUP, wb.id), { clear = true })

	-- WinScrolled covers horizontal scrolling too, which the leftcol sync needs.
	-- WinResized handles the pane being resized under the float, and BufWinEnter
	-- the buffer being shown in a new window (a split of the result pane).
	vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "BufWinEnter" }, {
		group = group,
		buffer = buf,
		callback = function()
			M.follow(wb, get_win())
		end,
	})

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buf,
		callback = function()
			M.skip_header(wb, get_win())
			M.follow(wb, get_win())
		end,
	})
end

--- The float is anchored to a window: leaving it behind orphans a one-line
--- window over whatever replaces the pane.
---@param wb table
function M.cleanup(wb)
	local s = st(wb)
	M.hide(wb)
	pcall(vim.api.nvim_del_augroup_by_name, ("%s%d"):format(AUGROUP, wb.id))

	if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
		pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
	end

	s.buf = nil
	s.header = nil
end

return M
