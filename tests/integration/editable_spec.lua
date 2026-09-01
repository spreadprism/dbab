-- Editing the grid, end to end, against real servers.
--
-- Covers both dialects because the quoting and the one-row guard differ between
-- them. Skipped when a server is unreachable.

local config = require("dbab.config")
local executor = require("dbab.core.executor")
local editable = require("dbab.ui.editable")
local query_ui = require("dbab.ui.query")
local workbench = require("dbab.ui.workbench")

local MYSQL_URL = os.getenv("DBAB_TEST_MYSQL_URL") or "mysql://root:root@127.0.0.1:3306/testdb"
local PG_URL = os.getenv("DBAB_TEST_PG_URL") or "postgres://postgres:postgres@127.0.0.1:5432/testdb"

config.setup({
	connections = {
		{ name = "my", url = MYSQL_URL },
		{ name = "pg", url = PG_URL },
	},
	layout = { { "sidebar", "editor" }, { "result" } },
})

---@param url string
---@return boolean
local function reachable(url)
	local out = executor.execute(url, "SELECT 1;")
	return out ~= nil and vim.trim(out) ~= "" and not executor.is_error(out)
end

local targets = {}
if vim.fn.executable("mysql") == 1 and reachable(MYSQL_URL) then
	table.insert(targets, { name = "my", url = MYSQL_URL, serial = "INT" })
end
if vim.fn.executable("psql") == 1 and reachable(PG_URL) then
	table.insert(targets, { name = "pg", url = PG_URL, serial = "int" })
end

describe("editable grid", function()
	if #targets == 0 then
		it("is skipped", function()
			pending("no reachable database", function() end)
		end)
		return
	end

	for _, target in ipairs(targets) do
		describe(target.name, function()
			local wb

			before_each(function()
				executor.execute(
					target.url,
					("DROP TABLE IF EXISTS dbab_edit; CREATE TABLE dbab_edit (id %s PRIMARY KEY, name varchar(32), note varchar(32));"):format(
						target.serial
					)
				)
				executor.execute(target.url, "INSERT INTO dbab_edit VALUES (1, 'ada', 'first'), (2, 'grace', NULL);")

				wb = workbench.open_for(target.name)
			end)

			after_each(function()
				executor.execute(target.url, "DROP TABLE IF EXISTS dbab_edit;")

				for name in pairs(vim.deepcopy(workbench.registry())) do
					workbench.close(name)
				end
				while #vim.api.nvim_list_tabpages() > 1 do
					vim.cmd("tabclose")
				end
			end)

			---@param sql string
			local function run(sql)
				vim.api.nvim_buf_set_lines(wb.editor_buf, 0, -1, false, { sql })
				query_ui.execute_query()
			end

			---@param row number 0-indexed buffer line
			---@param needle string
			---@param replacement string
			local function retype(row, needle, replacement)
				local line = vim.api.nvim_buf_get_lines(wb.result_buf, row, row + 1, false)[1]
				local from = line:find(needle, 1, true) - 1
				vim.api.nvim_buf_set_text(wb.result_buf, row, from, row, from + #needle, { replacement })
			end

			---@return string
			local function table_state()
				return executor.execute(target.url, "SELECT id, name, note FROM dbab_edit ORDER BY id;")
			end

			it("marks a plain single-table select editable", function()
				run("SELECT id, name, note FROM dbab_edit ORDER BY id;")

				local state = editable.state(wb.result_buf)

				assert.is_true(state.editable, tostring(state.reason))
				assert.are.same({ "id" }, state.keys)
				assert.are.equal("acwrite", vim.bo[wb.result_buf].buftype)
				assert.is_true(vim.bo[wb.result_buf].modifiable)
			end)

			it("refuses an aggregate and keeps the buffer read-only", function()
				run("SELECT COUNT(*) AS n FROM dbab_edit;")

				local state = editable.state(wb.result_buf)

				assert.is_false(state.editable)
				assert.is_false(vim.bo[wb.result_buf].modifiable)
			end)

			it("writes an edited cell back to the database", function()
				run("SELECT id, name, note FROM dbab_edit ORDER BY id;")
				retype(1, "ada", "ADA")

				local statements = editable.statements(wb.result_buf)
				assert.are.equal(1, #statements)

				local ok, err = editable.apply(wb.result_buf, statements)

				assert(ok, tostring(err))
				assert.is_not_nil(table_state():find("ADA", 1, true))
			end)

			it("writes a typed NULL as a real null", function()
				run("SELECT id, name, note FROM dbab_edit ORDER BY id;")
				retype(1, "first", "NULL")

				local ok, err = editable.apply(wb.result_buf, editable.statements(wb.result_buf))
				assert(ok, tostring(err))

				local after = executor.execute(target.url, "SELECT COUNT(*) AS n FROM dbab_edit WHERE note IS NULL;")

				assert.is_not_nil(after:find("2", 1, true))
			end)

			it("survives a value containing a quote", function()
				run("SELECT id, name, note FROM dbab_edit ORDER BY id;")
				retype(1, "ada", "O'Brien")

				local ok, err = editable.apply(wb.result_buf, editable.statements(wb.result_buf))

				assert(ok, tostring(err))
				assert.is_not_nil(table_state():find("O'Brien", 1, true))
			end)

			it("refuses to write when the row no longer matches", function()
				run("SELECT id, name, note FROM dbab_edit ORDER BY id;")
				retype(1, "ada", "ADA")

				-- The row goes away behind the editor's back.
				executor.execute(target.url, "DELETE FROM dbab_edit WHERE id = 1;")

				local ok, err = editable.apply(wb.result_buf, editable.statements(wb.result_buf))

				assert.is_false(ok)
				assert.is_not_nil(err:find("not matched exactly once", 1, true))
			end)

			it("refuses to write if another query replaced the result mid-prompt", function()
				executor.execute(target.url, "DROP TABLE IF EXISTS dbab_edit2;")
				executor.execute(
					target.url,
					("CREATE TABLE dbab_edit2 (id %s PRIMARY KEY, name varchar(32));"):format(target.serial)
				)
				executor.execute(target.url, "INSERT INTO dbab_edit2 VALUES (1, 'other');")

				run("SELECT id, name, note FROM dbab_edit ORDER BY id;")
				retype(1, "ada", "ADA")

				-- The confirmation is asynchronous: run a different query before
				-- answering it.
				local confirm = require("dbab.ui.confirm")
				local original_show = confirm.show
				confirm.show = function(_, cb)
					vim.api.nvim_buf_set_lines(wb.editor_buf, 0, -1, false, { "SELECT id, name FROM dbab_edit2 ORDER BY id;" })
					query_ui.execute_query()
					cb(true)
				end

				vim.api.nvim_set_current_win(wb.result_win)
				pcall(vim.cmd, "write")
				vim.wait(1000, function()
					return false
				end)

				confirm.show = original_show
				executor.execute(target.url, "DROP TABLE IF EXISTS dbab_edit2;")

				-- The statements were built against a grid that is no longer on
				-- screen, so nothing may be written.
				assert.is_nil(table_state():find("ADA", 1, true))
			end)

			it("records the applied statements in the history", function()
				local history = require("dbab.core.history")
				history.entries = {}

				run("SELECT id, name, note FROM dbab_edit ORDER BY id;")
				retype(1, "ada", "ADA")

				local statements = editable.statements(wb.result_buf)
				assert(#statements == 1, "expected one statement")

				local before = #history.get_all()

				local confirm = require("dbab.ui.confirm")
				local original_show = confirm.show
				confirm.show = function(_, cb)
					cb(true)
				end

				vim.api.nvim_set_current_win(wb.result_win)
				pcall(vim.cmd, "write")
				vim.wait(2000, function()
					return #history.get_all() > before
				end)

				confirm.show = original_show

				local entries = history.get_all()

				assert.are.equal(before + 1, #entries)
				assert.are.equal(statements[1], entries[1].query)
				assert.are.equal(target.name, entries[1].conn_name)
				assert.are.equal(1, entries[1].row_count)
			end)

			it("does not record anything when the write is declined", function()
				local history = require("dbab.core.history")
				history.entries = {}

				run("SELECT id, name, note FROM dbab_edit ORDER BY id;")
				retype(1, "ada", "ADA")

				local before = #history.get_all()

				local confirm = require("dbab.ui.confirm")
				local original_show = confirm.show
				confirm.show = function(_, cb)
					cb(false)
				end

				vim.api.nvim_set_current_win(wb.result_win)
				pcall(vim.cmd, "write")
				vim.wait(500, function()
					return false
				end)

				confirm.show = original_show

				assert.are.equal(before, #history.get_all())
			end)

			it("leaves other rows alone", function()
				run("SELECT id, name, note FROM dbab_edit ORDER BY id;")
				retype(1, "ada", "ADA")

				editable.apply(wb.result_buf, editable.statements(wb.result_buf))

				assert.is_not_nil(table_state():find("grace", 1, true))
			end)
		end)
	end
end)
