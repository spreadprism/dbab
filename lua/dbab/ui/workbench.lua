local connection = require("dbab.core.connection")
local config = require("dbab.config")
local hooks = require("dbab.core.hooks")

local result = require("dbab.ui.result")
local keymaps = require("dbab.ui.keymaps")
local tabs = require("dbab.ui.tabs")
local query = require("dbab.ui.query")
local winbar = require("dbab.ui.winbar")

local function get_sidebar()
	return require("dbab.ui.sidebar")
end

local function get_history_ui()
	return require("dbab.ui.history")
end

local DEFAULT_LAYOUT = {
	{ "sidebar", "editor" },
	{ "history", "result" },
}

---@param layout Dbab.LayoutRow[]
---@return boolean valid, string? error_message
local function validate_layout(layout)
	if not layout or #layout == 0 then
		return false, "Layout is empty"
	end

	local has_editor = false
	local has_result = false
	local seen = {}

	for _, row in ipairs(layout) do
		if type(row) ~= "table" or #row == 0 then
			return false, "Invalid row in layout"
		end
		for _, comp in ipairs(row) do
			if seen[comp] then
				return false, "Duplicate component: " .. comp
			end
			seen[comp] = true
			if comp == "editor" then
				has_editor = true
			end
			if comp == "result" then
				has_result = true
			end
		end
	end

	if not has_editor then
		return false, "Missing required component: editor"
	end
	if not has_result then
		return false, "Missing required component: result"
	end

	return true, nil
end

---@param row Dbab.LayoutRow
---@param total_width number
---@return table<string, number>
local function calculate_row_widths(row, total_width)
	local cfg = config.get()
	local fixed_widths = {
		sidebar = cfg.sidebar.width,
		history = cfg.history.width,
	}

	local fixed_total = 0
	local variable_count = 0

	for _, comp in ipairs(row) do
		if fixed_widths[comp] then
			fixed_total = fixed_total + fixed_widths[comp]
		else
			variable_count = variable_count + 1
		end
	end

	local variable_ratio = (1 - fixed_total) / math.max(1, variable_count)

	local widths = {}
	for _, comp in ipairs(row) do
		local ratio = fixed_widths[comp] or variable_ratio
		widths[comp] = math.floor(total_width * ratio)
	end

	return widths
end

local M = {}

-- ============================================
-- Workbench instances
-- ============================================
--
-- A workbench is one Neovim tabpage pinned to one connection. Instances live in
-- a registry keyed by connection name, so `:Dbab prod` always lands on the same
-- tabpage and two tabs can never drive the same database.
--
-- The module itself stays a facade: reading `workbench.editor_buf` resolves to
-- the instance owning the current tabpage. That keeps the existing call style
-- (and the child modules' `M.setup(workbench_ref)` idiom) intact instead of
-- threading an instance argument through several hundred call sites.

---@class Dbab.Workbench
---@field id number Monotonic, never reused -- used for augroup names
---@field conn_name string The connection this workbench is pinned to
---@field url string Resolved connection URL
---@field tab_nr number|nil Nil while closed
---@field closed boolean Guards against cleanup running twice
local Workbench = {}
Workbench.__index = Workbench

---@type table<string, Dbab.Workbench>
local registry = {}

local next_id = 1

--- The workbench most recently opened or focused.
---
--- `current()` answers "which workbench owns this tabpage", which is the right
--- question inside a keymap or an autocmd. Async callbacks can land while the
--- user is looking at some other tab, and they still have to render into the
--- workbench they were started for -- that is what this remembers.
---@type Dbab.Workbench|nil
local last_focused = nil

---@param wb Dbab.Workbench
---@return boolean
local function workbench_is_current(wb)
	return wb.tab_nr ~= nil
		and vim.api.nvim_tabpage_is_valid(wb.tab_nr)
		and vim.api.nvim_get_current_tabpage() == wb.tab_nr
end

---@param conn_name string
---@param url string
---@param register? boolean Defaults to true
---@return Dbab.Workbench
function Workbench.new(conn_name, url, register)
	local wb = setmetatable({
		id = next_id,
		conn_name = conn_name,
		url = url,
		tab_nr = nil,
		closed = false,

		sidebar_buf = nil,
		sidebar_win = nil,
		editor_buf = nil,
		editor_win = nil,
		result_buf = nil,
		result_win = nil,
		history_buf = nil,
		history_win = nil,

		tabs = { query_tabs = {}, active_tab = 0 },
		result = {
			last_result = nil,
			last_query = nil,
			last_duration = nil,
			last_conn_name = nil,
			last_timestamp = nil,
			last_result_width = nil,
		},
		sidebar = { nodes = {}, expanded = {}, is_loading = false, loading_conn_name = nil, loaded = false },
		sticky = { buf = nil, win = nil, header = nil },
		query = { history = {}, history_index = 0 },
		history_ui = { entry_line_map = {} },
	}, Workbench)

	next_id = next_id + 1

	if register ~= false then
		registry[conn_name] = wb
	end

	return wb
end

---@return boolean
function Workbench:is_open()
	return self.tab_nr ~= nil and vim.api.nvim_tabpage_is_valid(self.tab_nr)
end

--- Which workbench owns a tabpage, if any.
---@param tabpage? number Defaults to the current tabpage
---@return Dbab.Workbench|nil
function M.current(tabpage)
	tabpage = tabpage or vim.api.nvim_get_current_tabpage()

	for _, wb in pairs(registry) do
		if wb.tab_nr == tabpage then
			return wb
		end
	end

	return nil
end

--- The workbench to act on: the one owning this tabpage, else the last focused.
---@return Dbab.Workbench|nil
function M.resolve()
	local wb = M.current()
	if wb then
		last_focused = wb
		return wb
	end

	if last_focused and not last_focused.closed then
		return last_focused
	end

	return nil
end

---@param name string
---@return Dbab.Workbench|nil
function M.get(name)
	return registry[name]
end

---@return table<string, Dbab.Workbench>
function M.registry()
	return registry
end

---@return string[]
function M.open_names()
	local names = {}
	for name, wb in pairs(registry) do
		if wb:is_open() then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

-- A scratch instance so the module still answers sensibly (and tests can poke
-- at it) when no workbench has been opened.
local orphan = Workbench.new("", "", false)

---@return Dbab.Workbench
local function state()
	return M.resolve() or orphan
end

M._orphan = orphan
M._state = state

result.setup(M)
winbar.setup(M, result)
keymaps.setup(M)
tabs.setup(M)
query.setup(M)

--- Fields that live directly on the instance.
local DIRECT = {
	tab_nr = true,
	conn_name = true,
	url = true,
	sidebar_buf = true,
	sidebar_win = true,
	editor_win = true,
	editor_buf = true,
	result_buf = true,
	result_win = true,
	history_buf = true,
	history_win = true,
}

--- Fields the child modules still reach for by their old names.
local NESTED = {
	query_tabs = { "tabs", "query_tabs" },
	active_tab = { "tabs", "active_tab" },
	last_result = { "result", "last_result" },
	last_query = { "result", "last_query" },
	last_duration = { "result", "last_duration" },
	last_conn_name = { "result", "last_conn_name" },
	last_timestamp = { "result", "last_timestamp" },
	last_result_width = { "result", "last_result_width" },
	history = { "query", "history" },
	history_index = { "query", "history_index" },
}

setmetatable(M, {
	__index = function(_, k)
		if DIRECT[k] then
			return state()[k]
		end

		local path = NESTED[k]
		if path then
			return state()[path[1]][path[2]]
		end
	end,
	__newindex = function(t, k, v)
		if DIRECT[k] then
			state()[k] = v
			return
		end

		local path = NESTED[k]
		if path then
			state()[path[1]][path[2]] = v
			return
		end

		rawset(t, k, v)
	end,
})

function M.refresh_result_winbar()
	winbar.refresh_result()
end

function M.refresh_tabbar()
	tabs.refresh_tabbar()
end

function M.refresh_history()
	tabs.refresh_history()
end

function M.get_active_tab()
	return tabs.get_active_tab()
end

function M.get_active_connection_context()
	local active_tab = M.get_active_tab()
	local conn_name = active_tab and active_tab.conn_name or nil

	if conn_name then
		local url = connection.get_resolved_url_by_name(conn_name)
		if url then
			return conn_name, url
		end
	end

	-- Fall back to the workbench's own connection: a tab always belongs to one.
	local wb = M.resolve()
	if wb and wb.conn_name ~= "" then
		return wb.conn_name, wb.url
	end

	return nil, nil
end

function M.switch_tab(index)
	tabs.switch_tab(index)
end

function M.next_tab()
	tabs.next_tab()
end

function M.prev_tab()
	tabs.prev_tab()
end

function M.close_tab()
	tabs.close_tab()
end

function M.create_new_tab(name, content, conn_name, is_saved)
	return tabs.create_new_tab(name, content, conn_name, is_saved)
end

function M.show_result(raw, elapsed)
	result.show_result(raw, elapsed)
end

---@param opts Dbab.ExecuteOpts|nil
function M.execute_query(opts)
	query.execute_query(opts)
end

function M.save_query_by_buf(buf, callback)
	query.save_query_by_buf(buf, callback)
end

function M.save_current_query(callback)
	query.save_current_query(callback)
end

function M.open_saved_query(query_name, content, conn_name)
	query.open_saved_query(query_name, content, conn_name)
end

function M.setup_result_keymaps()
	keymaps.setup_result_keymaps()
end

function M.setup_editor_keymaps(buf)
	keymaps.setup_editor_keymaps(buf)
end

function M.setup_keymaps()
	keymaps.setup_keymaps()
end

function M.yank_current_row()
	result.yank_current_row()
end

function M.yank_all_rows()
	result.yank_all_rows()
end

--- Focus the workbench pinned to `conn_name`, building it if needed.
---@param conn_name string
---@return Dbab.Workbench|nil
--- Focus the workbench pinned to `conn_name`, building it if needed.
---
--- Returns the workbench directly when nothing has to happen first. With a
--- `pre_open` hook configured the work is asynchronous -- a tunnel or proxy has
--- to be up before the first query -- so the result arrives via `callback` and
--- the return value is nil.
---@param conn_name string
---@param callback? fun(wb: Dbab.Workbench|nil)
---@return Dbab.Workbench|nil
function M.open_for(conn_name, callback)
	callback = callback or function() end

	local url = connection.get_resolved_url_by_name(conn_name)
	if not url then
		vim.notify(("[dbab] Unknown connection: %s"):format(tostring(conn_name)), vim.log.levels.ERROR)
		callback(nil)
		return nil
	end

	local existing = registry[conn_name]
	local is_focus_only = existing
		and existing:is_open()
		and existing.sidebar_win
		and vim.api.nvim_win_is_valid(existing.sidebar_win)
		and existing.editor_win
		and vim.api.nvim_win_is_valid(existing.editor_win)
		and existing.result_win
		and vim.api.nvim_win_is_valid(existing.result_win)

	-- Focusing a workbench that is already up is not opening a connection, so
	-- the hooks must not run again.
	if not is_focus_only and hooks.has("pre_open", conn_name) then
		hooks.run("pre_open", { conn_name = conn_name, url = url, db_type = connection.parse_type(url) }, function(ok, err)
			if not ok then
				vim.notify(("[dbab] Not opening %s: %s"):format(conn_name, tostring(err)), vim.log.levels.ERROR)
				callback(nil)
				return
			end

			callback(M._build(conn_name, url))
		end)

		return nil
	end

	local wb = M._build(conn_name, url)
	callback(wb)

	return wb
end

---@param conn_name string
---@param url string
---@return Dbab.Workbench|nil
function M._build(conn_name, url)
	local wb = registry[conn_name]

	if wb and wb:is_open() then
		local wins_valid = wb.sidebar_win
			and vim.api.nvim_win_is_valid(wb.sidebar_win)
			and wb.editor_win
			and vim.api.nvim_win_is_valid(wb.editor_win)
			and wb.result_win
			and vim.api.nvim_win_is_valid(wb.result_win)

		if wins_valid then
			vim.api.nvim_set_current_tabpage(wb.tab_nr)
			last_focused = wb
			return wb
		end

		-- Half-torn-down: drop it and build a fresh one.
		wb:cleanup()
		pcall(function()
			vim.cmd("tabclose")
		end)
		wb = nil
	elseif wb then
		if not wb.closed then
			wb:cleanup()
		end
		registry[conn_name] = nil
		wb = nil
	end

	wb = Workbench.new(conn_name, url)
	-- Set before building: until `tab_nr` exists `current()` cannot find this
	-- instance, and every proxied write during construction must land on it.
	last_focused = wb

	if config._has_legacy_config then
		vim.notify(
			"[dbab] You are using a legacy config (ui.*). Please check the new flat config structure.",
			vim.log.levels.WARN
		)
	end

	local cfg = config.get()
	local layout = cfg.layout or DEFAULT_LAYOUT
	---@cast layout Dbab.LayoutRow[]

	local valid, err = validate_layout(layout)
	if not valid then
		vim.notify("[dbab] Invalid layout: " .. (err or "unknown") .. ". Using default.", vim.log.levels.WARN)
		layout = DEFAULT_LAYOUT
	end

	vim.cmd("tabnew")
	local initial_buf = vim.api.nvim_get_current_buf()
	wb.tab_nr = vim.api.nvim_get_current_tabpage()

	local total_width = vim.o.columns
	local total_height = vim.o.lines - 4
	local row_count = #layout
	local row_height = math.floor(total_height / row_count)

	local windows = {}
	local row_wins = { vim.api.nvim_get_current_win() }

	for row_idx = 2, row_count do
		vim.cmd("belowright split")
		row_wins[row_idx] = vim.api.nvim_get_current_win()
	end

	for row_idx, row in ipairs(layout) do
		local row_win = row_wins[row_idx]
		vim.api.nvim_set_current_win(row_win)

		windows[row[1]] = row_win

		for col_idx = 2, #row do
			local comp = row[col_idx]
			vim.cmd("belowright vsplit")
			windows[comp] = vim.api.nvim_get_current_win()
		end
	end

	for row_idx = 1, row_count - 1 do
		local row = layout[row_idx]
		local first_comp = row[1]
		if windows[first_comp] and vim.api.nvim_win_is_valid(windows[first_comp]) then
			vim.api.nvim_win_set_height(windows[first_comp], row_height)
		end
	end

	for _, row in ipairs(layout) do
		local row_widths = calculate_row_widths(row, total_width)
		for _, comp in ipairs(row) do
			local win = windows[comp]
			if win and vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_set_width(win, row_widths[comp])
			end
		end
	end

	M._init_all_components(wb, windows)

	pcall(vim.api.nvim_buf_delete, initial_buf, { force = true })

	if wb.sidebar_win and vim.api.nvim_win_is_valid(wb.sidebar_win) then
		vim.api.nvim_set_current_win(wb.sidebar_win)
	end

	M._setup_autocmds(wb)

	hooks.run("post_open", {
		conn_name = wb.conn_name,
		url = wb.url,
		db_type = wb.db_type,
		workbench = wb,
	}, function() end)

	return wb
end

--- Reopen the current (or last focused) workbench.
function M.open()
	local wb = M.resolve()
	if wb and wb.conn_name ~= "" then
		return M.open_for(wb.conn_name)
	end

	require("dbab").open()
end

---@param wb Dbab.Workbench
---@param windows table<string, number>
function M._init_all_components(wb, windows)
	local cfg = config.get()

	if windows.sidebar then
		wb.sidebar_win = windows.sidebar
		wb.sidebar_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(wb.sidebar_win, wb.sidebar_buf)
		get_sidebar().setup(wb.sidebar_buf, wb.sidebar_win)
	end

	if windows.editor then
		wb.editor_win = windows.editor
		M.create_new_tab(nil, nil, wb.conn_name, false)
	end

	if windows.result then
		wb.result_win = windows.result
		wb.result_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(wb.result_win, wb.result_buf)
		pcall(vim.api.nvim_buf_set_name, wb.result_buf, "[dbab] Result - " .. wb.conn_name)
		vim.bo[wb.result_buf].filetype = "dbab_result"
		vim.bo[wb.result_buf].buftype = "nofile"
		vim.bo[wb.result_buf].buflisted = false
		vim.bo[wb.result_buf].modifiable = false
		vim.wo[wb.result_win].cursorline = true
		vim.wo[wb.result_win].wrap = false
		vim.wo[wb.result_win].number = cfg.result.show_line_number
		vim.wo[wb.result_win].relativenumber = false
		M.setup_result_keymaps()
		require("dbab.ui.sticky").attach(wb, wb.result_buf, function()
			return wb.result_win
		end)
		vim.schedule(function()
			if not wb.closed and workbench_is_current(wb) then
				M.refresh_result_winbar()
			end
		end)
	end

	if windows.history then
		wb.history_win = windows.history
		wb.history_buf = get_history_ui().get_or_create_buf()
		vim.api.nvim_win_set_buf(wb.history_win, wb.history_buf)
		get_history_ui().setup(wb.history_win)
	end
end

---@param wb Dbab.Workbench
function M._setup_autocmds(wb)
	-- Named per instance: these events are global, and a shared augroup created
	-- with `clear = true` would wipe every other workbench's autocmds.
	local augroup = vim.api.nvim_create_augroup(("DbabWorkbench%d"):format(wb.id), { clear = true })
	wb.augroup = augroup

	vim.api.nvim_create_autocmd("TabClosed", {
		group = augroup,
		callback = function()
			-- `wb.tab_nr` is re-read from the instance every time, never captured:
			-- a restore gives the same workbench a new tabpage.
			if not wb.tab_nr or not vim.api.nvim_tabpage_is_valid(wb.tab_nr) then
				wb:cleanup()
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		callback = function(ev)
			if wb.tab_nr and vim.api.nvim_get_current_tabpage() ~= wb.tab_nr then
				return
			end

			local closed_win = tonumber(ev.match)
			if closed_win == wb.result_win then
				require("dbab.ui.sticky").hide(wb)
			end
			if closed_win == wb.editor_win then
				wb.editor_win = nil
				wb.editor_buf = nil
			end
			if closed_win == wb.sidebar_win then
				vim.schedule(function()
					if wb.tab_nr and vim.api.nvim_tabpage_is_valid(wb.tab_nr) then
						pcall(function()
							vim.cmd("tabclose")
						end)
					end
					wb:cleanup()
				end)
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = augroup,
		callback = function(ev)
			if not wb.tab_nr or vim.api.nvim_get_current_tabpage() ~= wb.tab_nr then
				return
			end

			if ev.event == "VimResized" then
				M._resize_layout()
			end

			get_history_ui().render()
			M.refresh_result_winbar()
			require("dbab.ui.sticky").follow(wb, wb.result_win)
		end,
	})
end

function M._resize_layout()
	local cfg = config.get()
	local layout = cfg.layout or DEFAULT_LAYOUT
	---@cast layout Dbab.LayoutRow[]
	local total_width = vim.o.columns
	local total_height = vim.o.lines - 4
	local row_count = #layout
	local row_height = math.floor(total_height / row_count)

	local comp_to_win = {
		sidebar = M.sidebar_win,
		editor = M.editor_win,
		history = M.history_win,
		result = M.result_win,
	}

	for row_idx, row in ipairs(layout) do
		local row_widths = calculate_row_widths(row, total_width)

		for _, comp in ipairs(row) do
			local win = comp_to_win[comp]
			if win and vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_set_width(win, row_widths[comp])
				if row_idx < row_count then
					vim.api.nvim_win_set_height(win, row_height)
				end
			end
		end
	end
end

---@param q? string
function M.open_editor(q)
	if not M.tab_nr or not vim.api.nvim_tabpage_is_valid(M.tab_nr) then
		M.open()
	end

	M.create_new_tab(nil, q, (M.resolve() or {}).conn_name, false)

	if M.editor_win and vim.api.nvim_win_is_valid(M.editor_win) then
		vim.api.nvim_set_current_win(M.editor_win)
		vim.cmd("startinsert!")
	end
end

---@param q string
function M.open_editor_with_query(q)
	M.open_editor(q)
end

--- Rebuild this workbench's layout in a fresh tabpage, keeping the instance
--- (and therefore its registry entry and query tabs' connection) intact.
function M.restore()
	local wb = M.resolve()
	if not wb or wb.conn_name == "" then
		return
	end

	local conn_name = wb.conn_name

	-- Close first, while the augroup still exists, so the TabClosed handler
	-- unregisters this instance instead of being deleted out from under it.
	if wb:is_open() and #vim.api.nvim_list_tabpages() > 1 then
		if vim.api.nvim_get_current_tabpage() ~= wb.tab_nr then
			vim.api.nvim_set_current_tabpage(wb.tab_nr)
		end
		pcall(function()
			vim.cmd("tabclose")
		end)
	end

	wb:cleanup()

	M.open_for(conn_name)
end

--- Put a workbench away.
---@param name? string Connection name; defaults to the current workbench
function M.close(name)
	local wb = name and registry[name] or M.resolve()
	if not wb or wb.conn_name == "" then
		return
	end

	if wb:is_open() then
		if #vim.api.nvim_list_tabpages() == 1 then
			-- `tabclose` on the last tabpage raises E784, so empty it instead.
			-- Done unconditionally: leaving the windows up would strand a
			-- tabpage with no workbench behind it.
			vim.api.nvim_set_current_tabpage(wb.tab_nr)
			vim.cmd("enew")
			vim.cmd("silent only")
		else
			if vim.api.nvim_get_current_tabpage() ~= wb.tab_nr then
				vim.api.nvim_set_current_tabpage(wb.tab_nr)
			end
			pcall(function()
				vim.cmd("tabclose")
			end)
		end
	end

	wb:cleanup()
end

--- Tear down and unregister. Idempotent: `TabClosed` and an explicit close can
--- both reach here for the same instance.
function Workbench:cleanup()
	if self.closed then
		return
	end
	self.closed = true

	-- Runs on every teardown path -- `:DbabClose`, `:tabclose`, closing the
	-- sidebar window -- because a proxy started for this connection has to come
	-- down however the tab went away. `pre_close` cannot veto: closing must
	-- always be possible.
	local context = {
		conn_name = self.conn_name,
		url = self.url,
		db_type = self.db_type,
		workbench = self,
	}

	if self.conn_name ~= "" then
		hooks.run("pre_close", context, function() end)
	end

	if self.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
		self.augroup = nil
	end

	require("dbab.ui.sticky").cleanup(self)

	-- This instance owns these buffers; the child modules' own cleanup paths
	-- run through the facade and would resolve to whichever workbench happens
	-- to be current, so the deletion is done here from `self`.
	for _, tab in ipairs(self.tabs.query_tabs) do
		if tab.buf and vim.api.nvim_buf_is_valid(tab.buf) then
			pcall(vim.api.nvim_buf_delete, tab.buf, { force = true })
		end
	end

	if self.result_buf then
		require("dbab.ui.editable").detach(self.result_buf)
	end

	for _, buf in ipairs({ self.sidebar_buf, self.result_buf, self.history_buf }) do
		if buf and vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end

	self.tab_nr = nil
	self.sidebar_buf = nil
	self.sidebar_win = nil
	self.editor_buf = nil
	self.editor_win = nil
	self.result_buf = nil
	self.result_win = nil
	self.history_buf = nil
	self.history_win = nil

	self.tabs.query_tabs = {}
	self.tabs.active_tab = 0
	self.result = {}
	self.sidebar.nodes = {}
	self.sidebar.expanded = {}
	self.sidebar.is_loading = false
	self.sidebar.loaded = false
	self.query.history = {}
	self.query.history_index = 0
	self.history_ui = { entry_line_map = {} }

	if registry[self.conn_name] == self then
		registry[self.conn_name] = nil
	end

	if last_focused == self then
		last_focused = nil
	end

	if self.conn_name ~= "" then
		hooks.run("post_close", context, function() end)
	end
end

--- Kept for callers that still tear down "the" workbench.
function M.cleanup()
	local wb = M.resolve()
	if wb and wb.conn_name ~= "" then
		wb:cleanup()
	end
end

return M
