local config = require("dbab.config")
local tabs = require("dbab.ui.tabs")
local workbench = require("dbab.ui.workbench")

-- Everything that acts on "the current connection" resolves it through the
-- active query tab, then through the workbench the tab belongs to -- never
-- through a session-global active connection, which no longer exists.
describe("workbench connection context", function()
	local wb

	before_each(function()
		config.setup({
			connections = {
				{ name = "alpha", url = "sqlite:///tmp/dbab_alpha.sqlite" },
				{ name = "beta", url = "sqlite:///tmp/dbab_beta.sqlite" },
			},
			layout = { { "sidebar", "editor" }, { "result" } },
		})
		wb = workbench.open_for("alpha")
	end)

	after_each(function()
		for name in pairs(vim.deepcopy(workbench.registry())) do
			workbench.close(name)
		end
		while #vim.api.nvim_list_tabpages() > 1 do
			vim.cmd("tabclose")
		end
	end)

	it("resolves the active tab's connection", function()
		tabs.query_tabs = { { buf = 0, name = "q", conn_name = "beta", modified = false, is_saved = false } }
		tabs.active_tab = 1

		local name, url = workbench.get_active_connection_context()

		assert.are.equal("beta", name)
		assert.are.equal("sqlite:///tmp/dbab_beta.sqlite", url)
	end)

	it("falls back to the workbench's own connection when the tab names none", function()
		tabs.query_tabs = { { buf = 0, name = "q", conn_name = nil, modified = false, is_saved = false } }
		tabs.active_tab = 1

		local name, url = workbench.get_active_connection_context()

		assert.are.equal("alpha", name)
		assert.are.equal("sqlite:///tmp/dbab_alpha.sqlite", url)
	end)

	it("falls back when the tab names a connection that no longer exists", function()
		tabs.query_tabs = { { buf = 0, name = "q", conn_name = "gone", modified = false, is_saved = false } }
		tabs.active_tab = 1

		local name = workbench.get_active_connection_context()

		assert.are.equal("alpha", name)
	end)

	it("is used by query execution rather than a global connection", function()
		local query = require("dbab.ui.query")
		local executor = require("dbab.core.executor")

		tabs.query_tabs = { { buf = 0, name = "q", conn_name = "beta", modified = false, is_saved = false } }
		tabs.active_tab = 1

		local seen_url
		local original = executor.execute
		executor.execute = function(url)
			seen_url = url
			return "a\n1"
		end

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT 1;" })
		wb.editor_buf = buf
		tabs.query_tabs[1].buf = buf

		local ok, err = pcall(query.execute_query)

		executor.execute = original
		vim.api.nvim_buf_delete(buf, { force = true })

		assert(ok, tostring(err))
		assert.are.equal("sqlite:///tmp/dbab_beta.sqlite", seen_url)
	end)

	it("gives each workbench its own context", function()
		local beta = workbench.open_for("beta")

		vim.api.nvim_set_current_tabpage(wb.tab_nr)
		local alpha_name = workbench.get_active_connection_context()

		vim.api.nvim_set_current_tabpage(beta.tab_nr)
		local beta_name = workbench.get_active_connection_context()

		assert.are.equal("alpha", alpha_name)
		assert.are.equal("beta", beta_name)
	end)
end)
