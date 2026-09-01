if vim.g.loaded_dbab then
	return
end
vim.g.loaded_dbab = true

--- Subcommands win over connection names of the same spelling.
local RESERVED = {
	list = true,
	query = true,
	q = true,
}

---@return string[]
local function connection_names()
	local dbab = require("dbab")
	return vim.tbl_map(function(conn)
		return conn.name
	end, dbab.core.connection.list_connections())
end

vim.api.nvim_create_user_command("Dbab", function(opts)
	local dbab = require("dbab")
	local args = opts.fargs

	if #args == 0 then
		dbab.open()
		return
	end

	local subcmd = args[1]

	if not RESERVED[subcmd] then
		-- Anything that is not a subcommand is a connection name.
		dbab.open(subcmd)
		return
	end

	if subcmd == "list" then
		dbab.list_connections()
		return
	end

	local query = table.concat(vim.list_slice(args, 2), " ")
	if query == "" then
		vim.notify("[dbab] Usage: :Dbab query <sql>", vim.log.levels.WARN)
		return
	end

	local result = dbab.execute(query)
	if result ~= "" then
		print(result)
	end
end, {
	nargs = "*",
	complete = function(arg_lead, cmd_line, _)
		local args = vim.split(cmd_line, "%s+")

		if #args <= 2 then
			local candidates = { "list", "query" }
			vim.list_extend(candidates, connection_names())

			return vim.tbl_filter(function(s)
				return s:match("^" .. vim.pesc(arg_lead))
			end, candidates)
		end

		return {}
	end,
	desc = "Database client for Neovim",
})

vim.api.nvim_create_user_command("DbabClose", function(opts)
	require("dbab").close(opts.fargs[1])
end, {
	nargs = "?",
	complete = function(arg_lead)
		local open = require("dbab").ui.workbench.open_names()
		return vim.tbl_filter(function(s)
			return s:match("^" .. vim.pesc(arg_lead))
		end, open)
	end,
	desc = "Close a Dbab workbench",
})

vim.api.nvim_create_user_command("DbabRestore", function()
	require("dbab").restore()
end, {
	desc = "Restore the Dbab workbench layout",
})
