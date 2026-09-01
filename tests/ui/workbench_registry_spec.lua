local config = require("dbab.config")
local workbench = require("dbab.ui.workbench")

-- One tabpage per connection: the registry is the single source of truth for
-- which connection owns which tabpage.
describe("workbench registry", function()
	before_each(function()
		config.setup({
			connections = {
				{ name = "alpha", url = "sqlite:///tmp/dbab_alpha.sqlite" },
				{ name = "beta", url = "sqlite:///tmp/dbab_beta.sqlite" },
			},
			layout = { { "sidebar", "editor" }, { "result" } },
		})
	end)

	after_each(function()
		for name in pairs(vim.deepcopy(workbench.registry())) do
			workbench.close(name)
		end
		-- Leave the harness on a single, ordinary tabpage.
		while #vim.api.nvim_list_tabpages() > 1 do
			vim.cmd("tabclose")
		end
	end)

	it("registers a workbench under its connection name", function()
		local wb = workbench.open_for("alpha")

		assert.is_not_nil(wb)
		assert.are.equal("alpha", wb.conn_name)
		assert.are.equal("sqlite:///tmp/dbab_alpha.sqlite", wb.url)
		assert.are.equal(wb, workbench.get("alpha"))
		assert.is_true(wb:is_open())
	end)

	it("gives each connection its own tabpage", function()
		local alpha = workbench.open_for("alpha")
		local alpha_tab = alpha.tab_nr

		local beta = workbench.open_for("beta")

		assert.are_not.equal(alpha_tab, beta.tab_nr)
		assert.are.same({ "alpha", "beta" }, workbench.open_names())
	end)

	it("focuses the existing tabpage instead of opening a second one", function()
		local first = workbench.open_for("alpha")
		local tab = first.tab_nr
		local tab_count = #vim.api.nvim_list_tabpages()

		local again = workbench.open_for("alpha")

		assert.are.equal(first, again)
		assert.are.equal(tab, again.tab_nr)
		assert.are.equal(tab_count, #vim.api.nvim_list_tabpages())
	end)

	it("resolves the workbench owning the current tabpage", function()
		local alpha = workbench.open_for("alpha")
		local beta = workbench.open_for("beta")

		assert.are.equal(beta, workbench.current())

		vim.api.nvim_set_current_tabpage(alpha.tab_nr)
		assert.are.equal(alpha, workbench.current())

		vim.api.nvim_set_current_tabpage(beta.tab_nr)
		assert.are.equal(beta, workbench.current())
	end)

	it("returns nil from a tabpage that is not a workbench", function()
		workbench.open_for("alpha")

		vim.cmd("tabnew")
		assert.is_nil(workbench.current())
		vim.cmd("tabclose")
	end)

	it("keeps each workbench's state separate", function()
		local alpha = workbench.open_for("alpha")
		local beta = workbench.open_for("beta")

		alpha.result.last_query = "SELECT 1;"
		beta.result.last_query = "SELECT 2;"

		assert.are.equal("SELECT 1;", alpha.result.last_query)
		assert.are.equal("SELECT 2;", beta.result.last_query)
		assert.are_not.equal(alpha.tabs, beta.tabs)
		assert.are_not.equal(alpha.sidebar.expanded, beta.sidebar.expanded)
	end)

	it("gives each workbench its own augroup", function()
		local alpha = workbench.open_for("alpha")
		local beta = workbench.open_for("beta")

		assert.are_not.equal(alpha.id, beta.id)
		assert.are_not.equal(alpha.augroup, beta.augroup)
	end)

	it("unregisters on close", function()
		workbench.open_for("alpha")
		assert.is_not_nil(workbench.get("alpha"))

		workbench.close("alpha")

		assert.is_nil(workbench.get("alpha"))
		assert.are.same({}, workbench.open_names())
	end)

	it("survives cleanup being run twice", function()
		local wb = workbench.open_for("alpha")

		wb:cleanup()
		local ok, err = pcall(function()
			wb:cleanup()
		end)

		assert(ok, tostring(err))
		assert.is_nil(workbench.get("alpha"))
	end)

	it("refuses an unknown connection", function()
		local wb = workbench.open_for("nope")

		assert.is_nil(wb)
		assert.is_nil(workbench.get("nope"))
	end)

	it("rebuilds after the tabpage is closed behind its back", function()
		local first = workbench.open_for("alpha")
		vim.api.nvim_set_current_tabpage(first.tab_nr)
		vim.cmd("tabclose")

		local second = workbench.open_for("alpha")

		assert.is_not_nil(second)
		assert.is_true(second:is_open())
	end)

	it("restores into a fresh tabpage without leaking the registry entry", function()
		local first = workbench.open_for("alpha")
		local first_tab = first.tab_nr

		vim.api.nvim_set_current_tabpage(first_tab)
		workbench.restore()

		local restored = workbench.get("alpha")

		assert.is_not_nil(restored)
		assert.is_true(restored:is_open())
		assert.is_false(vim.api.nvim_tabpage_is_valid(first_tab))
		assert.are.same({ "alpha" }, workbench.open_names())
	end)

	it("does not strand a tabpage when closing the last one", function()
		local wb = workbench.open_for("alpha")
		local tab = wb.tab_nr

		-- Collapse to a single tabpage so close() takes the enew path.
		vim.api.nvim_set_current_tabpage(tab)
		for _, other in ipairs(vim.api.nvim_list_tabpages()) do
			if other ~= tab then
				vim.api.nvim_set_current_tabpage(other)
				vim.cmd("tabclose")
			end
		end

		workbench.close("alpha")

		assert.is_nil(workbench.get("alpha"))
		-- Whatever is left must not still be showing the workbench windows.
		assert.are.equal(1, #vim.api.nvim_list_tabpages())
		assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage()))
	end)

	it("deletes the buffers it owned", function()
		local wb = workbench.open_for("alpha")
		local bufs = { wb.sidebar_buf, wb.result_buf, wb.history_buf }

		workbench.close("alpha")

		for _, buf in ipairs(bufs) do
			if buf then
				assert.is_false(vim.api.nvim_buf_is_valid(buf), "buffer " .. buf .. " outlived its workbench")
			end
		end
	end)

	it("keeps each workbench's history line map separate", function()
		local history = require("dbab.ui.history")
		local alpha = workbench.open_for("alpha")
		local beta = workbench.open_for("beta")

		vim.api.nvim_set_current_tabpage(alpha.tab_nr)
		history.entry_line_map = { { start = 1, finish = 2 } }

		vim.api.nvim_set_current_tabpage(beta.tab_nr)
		history.entry_line_map = { { start = 5, finish = 6 }, { start = 7, finish = 8 } }

		vim.api.nvim_set_current_tabpage(alpha.tab_nr)
		assert.are.equal(1, #history.entry_line_map)

		vim.api.nvim_set_current_tabpage(beta.tab_nr)
		assert.are.equal(2, #history.entry_line_map)
	end)
end)
