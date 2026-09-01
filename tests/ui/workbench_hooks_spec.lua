local config = require("dbab.config")
local workbench = require("dbab.ui.workbench")

-- The reason these exist: a connection may need a tunnel or proxy standing up
-- before the first query and torn down when the tab goes away.
describe("workbench lifecycle hooks", function()
	local events

	---@param name string
	---@return function
	local function record(name)
		return function(ctx)
			table.insert(events, { name = name, conn = ctx.conn_name, url = ctx.url, wb = ctx.workbench })
		end
	end

	---@param hooks table
	local function setup(hooks)
		events = {}
		config.setup({
			connections = { { name = "alpha", url = "sqlite:///tmp/dbab_hooks.sqlite", hooks = hooks } },
			layout = { { "sidebar", "editor" }, { "result" } },
		})
	end

	---@return string[]
	local function names()
		return vim.tbl_map(function(e)
			return e.name
		end, events)
	end

	after_each(function()
		for name in pairs(vim.deepcopy(workbench.registry())) do
			workbench.close(name)
		end
		while #vim.api.nvim_list_tabpages() > 1 do
			vim.cmd("tabclose")
		end
	end)

	it("runs pre_open then post_open", function()
		setup({ pre_open = record("pre_open"), post_open = record("post_open") })

		workbench.open_for("alpha")
		vim.wait(500, function()
			return #events >= 2
		end)

		assert.are.same({ "pre_open", "post_open" }, names())
	end)

	it("gives pre_open the resolved url before anything is built", function()
		setup({
			pre_open = function(ctx)
				table.insert(events, { name = "pre_open", url = ctx.url, open = #workbench.open_names() })
			end,
		})

		workbench.open_for("alpha")
		vim.wait(500, function()
			return #events >= 1
		end)

		assert.are.equal("sqlite:///tmp/dbab_hooks.sqlite", events[1].url)
		assert.are.equal(0, events[1].open)
	end)

	it("hands post_open the workbench", function()
		setup({ post_open = record("post_open") })

		local wb = workbench.open_for("alpha")
		vim.wait(500, function()
			return #events >= 1
		end)

		assert.are.equal(wb, events[1].wb)
	end)

	it("waits for an asynchronous pre_open before building", function()
		local built_during_hook
		setup({
			pre_open = function(_, done)
				built_during_hook = #workbench.open_names()
				vim.defer_fn(function()
					done(true)
				end, 30)
			end,
		})

		local returned = workbench.open_for("alpha")

		-- Asynchronous: nothing is returned synchronously.
		assert.is_nil(returned)

		vim.wait(1000, function()
			return workbench.get("alpha") ~= nil
		end)

		assert.are.equal(0, built_during_hook)
		assert.is_not_nil(workbench.get("alpha"))
	end)

	it("passes the workbench to the callback when a hook is async", function()
		setup({
			pre_open = function(_, done)
				done(true)
			end,
		})

		local from_callback
		workbench.open_for("alpha", function(wb)
			from_callback = wb
		end)

		vim.wait(1000, function()
			return from_callback ~= nil
		end)

		assert.are.equal(workbench.get("alpha"), from_callback)
	end)

	it("does not open when pre_open refuses", function()
		setup({
			pre_open = function(_, done)
				done(false, "tunnel is down")
			end,
		})

		local from_callback = "unset"
		workbench.open_for("alpha", function(wb)
			from_callback = wb
		end)

		vim.wait(1000, function()
			return from_callback ~= "unset"
		end)

		assert.is_nil(from_callback)
		assert.is_nil(workbench.get("alpha"))
		assert.are.same({}, workbench.open_names())
	end)

	it("does not re-run the hooks when focusing an open workbench", function()
		setup({ pre_open = record("pre_open"), post_open = record("post_open") })

		workbench.open_for("alpha")
		vim.wait(500, function()
			return #events >= 2
		end)

		workbench.open_for("alpha")
		vim.wait(200, function()
			return false
		end)

		assert.are.equal(2, #events)
	end)

	it("runs pre_close then post_close on an explicit close", function()
		setup({ pre_close = record("pre_close"), post_close = record("post_close") })

		workbench.open_for("alpha")
		events = {}

		workbench.close("alpha")
		vim.wait(500, function()
			return #events >= 2
		end)

		assert.are.same({ "pre_close", "post_close" }, names())
	end)

	it("runs the close hooks when the tabpage is closed directly", function()
		setup({ pre_close = record("pre_close"), post_close = record("post_close") })

		local wb = workbench.open_for("alpha")
		events = {}

		vim.api.nvim_set_current_tabpage(wb.tab_nr)
		vim.cmd("tabclose")
		vim.wait(500, function()
			return #events >= 2
		end)

		assert.are.same({ "pre_close", "post_close" }, names())
		assert.is_nil(workbench.get("alpha"))
	end)

	it("runs the close hooks exactly once", function()
		setup({ post_close = record("post_close") })

		local wb = workbench.open_for("alpha")
		events = {}

		wb:cleanup()
		wb:cleanup()
		vim.wait(300, function()
			return false
		end)

		assert.are.equal(1, #events)
	end)

	it("names the connection in every event", function()
		setup({
			pre_open = record("pre_open"),
			post_open = record("post_open"),
			pre_close = record("pre_close"),
			post_close = record("post_close"),
		})

		workbench.open_for("alpha")
		vim.wait(500, function()
			return #events >= 2
		end)
		workbench.close("alpha")
		vim.wait(500, function()
			return #events >= 4
		end)

		for _, event in ipairs(events) do
			assert.are.equal("alpha", event.conn)
		end
	end)
end)
