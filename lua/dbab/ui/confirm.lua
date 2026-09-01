--- A single-keypress confirmation float, in the style of oil.nvim's.
---
--- Modelled on `oil.nvim`'s `lua/oil/mutator/confirmation.lua`: a centred
--- floating window showing exactly what is about to happen, answered with one
--- key rather than a typed response. The keys are buffer-local mappings with
--- `nowait`, not `getchar()`, so the rest of Neovim keeps working normally while
--- the prompt is up.
---@class Dbab.Confirm
local M = {}

--- Above a workbench's sticky header float (20), and out of the way of
--- treesitter-context.
local ZINDEX = 152

local CONFIRM_KEYS = { "y", "Y", "o", "O" }
local CANCEL_KEYS = { "n", "N", "q", "<Esc>", "<C-c>" }

---@class Dbab.ConfirmOpts
---@field lines string[] Body of the prompt
---@field prompt string Question shown under the body
---@field lang string|nil Treesitter language for the body
---@field min_width number|nil
---@field max_width number|nil
---@field max_height number|nil

--- Hide the cursor while the float is up: there is nothing to point at, and a
--- block cursor sitting on the SQL reads as an editing affordance it is not.
---@return fun()
local function hide_cursor()
	vim.api.nvim_set_hl(0, "DbabConfirmCursor", { nocombine = true, blend = 100 })
	local original = vim.go.guicursor

	vim.go.guicursor = "a:DbabConfirmCursor/DbabConfirmCursor"

	return function()
		-- See neovim/neovim#21018: guicursor needs a nudge to take effect again.
		vim.go.guicursor = "a:"
		pcall(vim.cmd.redrawstatus)
		vim.go.guicursor = original
	end
end

--- Syntax highlight the body, when a parser for it is actually installed.
---@param buf number
---@param lang string|nil
local function highlight(buf, lang)
	if not lang then
		return
	end

	local ok = pcall(vim.treesitter.language.add, lang)
	if ok then
		pcall(vim.treesitter.start, buf, lang)
	else
		vim.bo[buf].syntax = lang
	end
end

--- Ask the user to confirm, and call back with their answer.
---
--- Scheduled so the float is reliably entered before the keymaps matter.
---@param opts Dbab.ConfirmOpts
---@param callback fun(confirmed: boolean)
M.show = vim.schedule_wrap(function(opts, callback)
	local body = vim.deepcopy(opts.lines)

	local widest = vim.api.nvim_strwidth(opts.prompt)
	for _, line in ipairs(body) do
		widest = math.max(widest, vim.api.nvim_strwidth(line))
	end

	local min_width = opts.min_width or 40
	local max_width = opts.max_width or math.floor(vim.o.columns * 0.8)
	local max_height = opts.max_height or math.floor(vim.o.lines * 0.6)

	local width = math.max(min_width, math.min(widest + 2, max_width))
	-- Body, a blank line, and the prompt.
	local height = math.min(#body + 2, max_height)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
	highlight(buf, opts.lang)

	local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " dbab ",
		title_pos = "center",
		footer = " [y]es  [n]o ",
		footer_pos = "center",
		zindex = ZINDEX,
	})

	if not ok then
		vim.notify("[dbab] Could not open the confirmation window: " .. tostring(win), vim.log.levels.ERROR)
		callback(false)
		return
	end

	-- The prompt sits below the body as virtual lines, so it cannot be confused
	-- with the SQL and is not part of the highlighted region.
	local ns = vim.api.nvim_create_namespace("dbab_confirm")
	vim.api.nvim_buf_set_extmark(buf, ns, math.max(#body - 1, 0), 0, {
		virt_lines = {
			{ { "", "Normal" } },
			{ { opts.prompt, "DbabConfirmPrompt" } },
		},
	})

	vim.wo[win].wrap = false
	vim.wo[win].cursorline = false
	vim.bo[buf].modifiable = false

	local restore_cursor = hide_cursor()
	local autocmds = {}
	local answered = false

	---@param value boolean
	local function make_callback(value)
		return function()
			if answered then
				return
			end
			answered = true

			for _, id in ipairs(autocmds) do
				pcall(vim.api.nvim_del_autocmd, id)
			end

			if vim.api.nvim_win_is_valid(win) then
				pcall(vim.api.nvim_win_close, win, true)
			end

			restore_cursor()
			callback(value)
		end
	end

	local confirm = make_callback(true)
	local cancel = make_callback(false)

	-- Leaving the window at all is a refusal: an unanswered prompt must never
	-- leave the statements in limbo.
	table.insert(
		autocmds,
		vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
			buffer = buf,
			once = true,
			nested = true,
			callback = function()
				cancel()
			end,
		})
	)

	for _, key in ipairs(CONFIRM_KEYS) do
		vim.keymap.set("n", key, confirm, { buffer = buf, nowait = true })
	end

	for _, key in ipairs(CANCEL_KEYS) do
		vim.keymap.set("n", key, cancel, { buffer = buf, nowait = true })
	end
end)

return M
