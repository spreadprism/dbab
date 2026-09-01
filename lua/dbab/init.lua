local M = {}

M.config = require("dbab.config")
M.core = require("dbab.core")
M.ui = require("dbab.ui")

---@param opts? Dbab.Config
function M.setup(opts)
	M.config.setup(opts)
	M.ui.highlights.setup()

	-- Register CMP source if nvim-cmp is available
	local has_cmp, cmp = pcall(require, "cmp")
	if has_cmp then
		cmp.register_source("dbab", require("cmp_dbab").new())
	end
end

--- Open a workbench, asking which connection when not told.
---
--- Each connection gets its own tabpage; naming one that is already open
--- focuses that tabpage rather than building a second.
---@param name? string connection name
function M.open(name)
	if name ~= nil then
		M.ui.workbench.open_for(name)
		return
	end

	local names = vim.tbl_map(function(conn)
		return conn.name
	end, M.core.connection.list_connections())
	table.sort(names)

	if #names == 0 then
		vim.notify("[dbab] No connections configured", vim.log.levels.WARN)
		return
	end

	-- The only connection needs no choosing: asking the user to confirm their
	-- one option is ceremony, and one database is the common case.
	if #names == 1 then
		M.ui.workbench.open_for(names[1])
		return
	end

	-- `vim.ui.select` is asynchronous and cancellable, so everything past the
	-- choice happens in the callback. It opens by *name*, so it stays correct
	-- even if the user moves tabs while the prompt is up.
	vim.ui.select(names, { prompt = "dbab: open connection" }, function(choice)
		if choice == nil then
			return
		end

		M.ui.workbench.open_for(choice)
	end)
end

--- Execute a query against the current workbench's connection
---@param query string
---@return string
function M.execute(query)
	local wb = M.ui.workbench.current()
	if not wb then
		vim.notify("[dbab] Not in a dbab workbench. Open one with :Dbab first.", vim.log.levels.WARN)
		return ""
	end

	return M.core.executor.execute(wb.url, query)
end

--- Deprecated: connections are now opened, not switched to.
---@param name string
function M.connect(name)
	vim.notify("[dbab] `connect` is deprecated, use `:Dbab " .. tostring(name) .. "`", vim.log.levels.WARN)
	M.open(name)
end

--- Deprecated alias for `open()`.
function M.pick_connection()
	vim.notify("[dbab] `pick_connection` is deprecated, use `:Dbab`", vim.log.levels.WARN)
	M.open()
end

--- List available connections
function M.list_connections()
	local connections = M.core.connection.list_connections()
	if #connections == 0 then
		vim.notify("[dbab] No connections configured", vim.log.levels.WARN)
		return
	end

	local lines = { "Available connections:" }
	for i, conn in ipairs(connections) do
		local open = M.ui.workbench.get(conn.name) and " (open)" or ""
		table.insert(lines, string.format("  %d. %s%s", i, conn.name, open))
	end
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Close a workbench
---@param name? string connection name; defaults to the current workbench
function M.close(name)
	M.ui.workbench.close(name)
end

--- Restore the workbench layout
function M.restore()
	M.ui.workbench.restore()
end

return M
