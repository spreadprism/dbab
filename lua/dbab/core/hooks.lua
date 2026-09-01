local config = require("dbab.config")

--- Lifecycle hooks around a workbench's connection.
---
--- The point of these is work that has to happen *around* a connection rather
--- than inside it -- starting an SSH tunnel or a cloud SQL proxy before the
--- first query, and tearing it down when the tab closes.
---
--- Hooks may be synchronous or asynchronous. A hook declaring a second
--- parameter is treated as asynchronous and must call it:
---
--- ```lua
--- hooks = {
---   pre_open = function(ctx, done)
---     require("overseer").new_task({ cmd = { "cloud-sql-proxy", ctx.url } }):start()
---     vim.defer_fn(function() done(true) end, 2000)
---   end,
---   post_close = function(ctx)
---     vim.fn.system({ "pkill", "-f", "cloud-sql-proxy" })
---   end,
--- }
--- ```
---@class Dbab.Hooks
local M = {}

---@alias Dbab.HookEvent "pre_open"|"post_open"|"pre_close"|"post_close"

---@class Dbab.HookContext
---@field conn_name string
---@field url string|nil Resolved connection URL
---@field db_type string|nil
---@field event Dbab.HookEvent
---@field workbench table|nil Present for post_open and the close events

--- Only `pre_open` may refuse: closing has to stay possible, or a broken hook
--- would trap the user in a tab they cannot shut.
local CAN_VETO = { pre_open = true }

--- A hook that declares a second parameter is asynchronous and owns the
--- callback; one that does not is run inline.
---@param fn function
---@return boolean
local function is_async(fn)
	local ok, info = pcall(debug.getinfo, fn, "u")

	return ok and info ~= nil and (info.nparams or 0) >= 2
end

---@param value function|function[]|nil
---@return function[]
local function as_list(value)
	if value == nil then
		return {}
	end

	if type(value) == "function" then
		return { value }
	end

	if type(value) == "table" then
		return value
	end

	return {}
end

--- Hooks for an event: the global ones first, then the connection's own.
---@param event Dbab.HookEvent
---@param conn_name string
---@return function[]
function M.collect(event, conn_name)
	local cfg = config.get() or {}
	local hooks = {}

	vim.list_extend(hooks, as_list((cfg.hooks or {})[event]))

	for _, conn in ipairs(cfg.connections or {}) do
		if conn.name == conn_name then
			vim.list_extend(hooks, as_list((conn.hooks or {})[event]))
			break
		end
	end

	return hooks
end

---@param event Dbab.HookEvent
---@param conn_name string
---@return boolean
function M.has(event, conn_name)
	return #M.collect(event, conn_name) > 0
end

--- Run every hook for an event, in order, waiting for the asynchronous ones.
---
--- `callback` receives false only when a vetoing event was refused or a hook
--- raised; a `post_*` hook that fails is reported but does not stop anything,
--- because by then the thing it was reacting to has already happened.
---@param event Dbab.HookEvent
---@param ctx Dbab.HookContext
---@param callback fun(ok: boolean, err: string|nil)
function M.run(event, ctx, callback)
	local hooks = M.collect(event, ctx.conn_name)

	if #hooks == 0 then
		callback(true, nil)
		return
	end

	ctx = vim.tbl_extend("force", ctx, { event = event })

	local index = 0

	local function step()
		index = index + 1

		local hook = hooks[index]
		if not hook then
			callback(true, nil)
			return
		end

		---@param ok boolean|nil
		---@param err string|nil
		local function done(ok, err)
			if ok == false then
				local reason = err or ("%s hook refused"):format(event)

				if CAN_VETO[event] then
					callback(false, reason)
				else
					vim.notify(("[dbab] %s hook failed: %s"):format(event, reason), vim.log.levels.WARN)
					step()
				end

				return
			end

			step()
		end

		if is_async(hook) then
			local ok, err = pcall(hook, ctx, vim.schedule_wrap(done))
			if not ok then
				done(false, tostring(err))
			end
			return
		end

		local ok, result = pcall(hook, ctx)
		if not ok then
			done(false, tostring(result))
			return
		end

		-- A synchronous hook can still refuse by returning false.
		done(result ~= false, nil)
	end

	step()
end

return M
