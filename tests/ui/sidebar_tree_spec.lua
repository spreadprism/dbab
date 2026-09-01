local config = require("dbab.config")
local sidebar = require("dbab.ui.sidebar")
local workbench = require("dbab.ui.workbench")

-- The explorer belongs to a workbench that is already pinned to a connection,
-- so the tree starts at that connection's sections. Repeating the connection
-- name as a root node would just be a row you can never usefully collapse.
describe("sidebar tree", function()
	local wb

	before_each(function()
		config.setup({
			connections = { { name = "alpha", url = "sqlite:///tmp/dbab_sidebar_tree.sqlite" } },
			layout = { { "sidebar", "editor" }, { "result" } },
		})
		wb = workbench.open_for("alpha")
		vim.wait(2000, function()
			return not wb.sidebar.is_loading
		end)
		sidebar.refresh()
	end)

	after_each(function()
		for name in pairs(vim.deepcopy(workbench.registry())) do
			workbench.close(name)
		end
		while #vim.api.nvim_list_tabpages() > 1 do
			vim.cmd("tabclose")
		end
	end)

	---@return string[]
	local function lines()
		return vim.api.nvim_buf_get_lines(wb.sidebar_buf, 0, -1, false)
	end

	it("has no connection row", function()
		for _, line in ipairs(lines()) do
			assert.is_nil(line:match("alpha"), "connection name leaked into the tree: " .. line)
		end

		for _, node in ipairs(sidebar.nodes) do
			assert.are_not.equal("connection", node.type)
		end
	end)

	it("starts at buffers, saved queries and the schema section", function()
		local types = {}
		for _, node in ipairs(sidebar.nodes) do
			if node.depth == 0 then
				table.insert(types, node.type)
			end
		end

		assert.is_true(vim.tbl_contains(types, "buffers"))
		assert.is_true(vim.tbl_contains(types, "saved_queries"))
		assert.is_true(vim.tbl_contains(types, "tables") or vim.tbl_contains(types, "schemas"))
	end)

	it("keeps one node per rendered line", function()
		assert.are.equal(#lines(), #sidebar.nodes)
	end)

	it("renders the top level unindented", function()
		for i, node in ipairs(sidebar.nodes) do
			if node.depth == 0 then
				assert.is_nil(lines()[i]:match("^%s"), "top-level row is indented: " .. lines()[i])
			end
		end
	end)

	it("still toggles a section", function()
		local buffers_idx
		for i, node in ipairs(sidebar.nodes) do
			if node.type == "buffers" then
				buffers_idx = i
			end
		end
		assert.is_not_nil(buffers_idx)

		local before = #lines()
		vim.api.nvim_win_set_cursor(wb.sidebar_win, { buffers_idx, 0 })
		sidebar.toggle_node()

		assert.are_not.equal(before, #lines())
		assert.are.equal(#lines(), #sidebar.nodes)
	end)

	it("names the connection in the winbar", function()
		local winbar = vim.api.nvim_win_get_option(wb.sidebar_win, "winbar")

		assert.is_not_nil(winbar:match("Explorer %(alpha%)"))
	end)
end)
