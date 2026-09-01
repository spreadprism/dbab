-- Two workbenches, two databases, two tabpages, at the same time.
--
-- Needs both containers from ~/workspace/nvim/test/compose.yaml. Skipped
-- automatically when either is unreachable.

local config = require("dbab.config")
local executor = require("dbab.core.executor")
local schema = require("dbab.core.schema")
local workbench = require("dbab.ui.workbench")

local MYSQL_URL = os.getenv("DBAB_TEST_MYSQL_URL") or "mysql://root:root@127.0.0.1:3306/testdb"
local PG_URL = os.getenv("DBAB_TEST_PG_URL") or "postgres://postgres:postgres@127.0.0.1:5432/testdb"

---@param url string
---@return boolean
local function reachable(url)
	local out = executor.execute(url, "SELECT 1;")
	return out ~= nil and vim.trim(out) ~= "" and not executor.is_error(out)
end

config.setup({
	connections = {
		{ name = "mysql-test", url = MYSQL_URL },
		{ name = "postgres-test", url = PG_URL },
	},
	layout = { { "sidebar", "editor" }, { "result" } },
})

local ok_mysql = vim.fn.executable("mysql") == 1 and reachable(MYSQL_URL)
local ok_pg = vim.fn.executable("psql") == 1 and reachable(PG_URL)

describe("multiple workbenches", function()
	if not (ok_mysql and ok_pg) then
		it("is skipped", function()
			pending(("needs both databases (mysql: %s, postgres: %s)"):format(tostring(ok_mysql), tostring(ok_pg)))
		end)
		return
	end

	before_each(function()
		schema.clear_cache()
	end)

	after_each(function()
		for name in pairs(vim.deepcopy(workbench.registry())) do
			workbench.close(name)
		end
		while #vim.api.nvim_list_tabpages() > 1 do
			vim.cmd("tabclose")
		end
		schema.clear_cache()
	end)

	it("pins each workbench to its own connection", function()
		local mysql = workbench.open_for("mysql-test")
		local pg = workbench.open_for("postgres-test")

		assert.are.equal(MYSQL_URL, mysql.url)
		assert.are.equal(PG_URL, pg.url)
		assert.are_not.equal(mysql.tab_nr, pg.tab_nr)
	end)

	it("executes each query against its own database", function()
		local mysql = workbench.open_for("mysql-test")
		local pg = workbench.open_for("postgres-test")

		vim.api.nvim_set_current_tabpage(mysql.tab_nr)
		local _, mysql_url = workbench.get_active_connection_context()
		local mysql_out = executor.execute(mysql_url, "SELECT VERSION() AS v;")

		vim.api.nvim_set_current_tabpage(pg.tab_nr)
		local _, pg_url = workbench.get_active_connection_context()
		local pg_out = executor.execute(pg_url, "SELECT version() AS v;")

		assert.is_not_nil(mysql_out:match("%d+%.%d+"))
		assert.is_not_nil(pg_out:match("PostgreSQL"))
		assert.is_nil(mysql_out:match("PostgreSQL"))
	end)

	it("keeps each workbench's last result separate", function()
		local mysql = workbench.open_for("mysql-test")
		local pg = workbench.open_for("postgres-test")

		mysql.result.last_query = "SELECT * FROM Users;"
		pg.result.last_query = "SELECT 1;"

		assert.are.equal("SELECT * FROM Users;", mysql.result.last_query)
		assert.are.equal("SELECT 1;", pg.result.last_query)
	end)

	it("sees the right schema from each workbench", function()
		local mysql = workbench.open_for("mysql-test")
		local pg = workbench.open_for("postgres-test")

		local mysql_schemas = schema.get_schemas(mysql.url)
		local pg_schemas = schema.get_schemas(pg.url)

		local mysql_names = vim.tbl_map(function(t)
			return t.name
		end, schema.get_tables(mysql.url, "testdb"))

		-- The mysql fixture has a Users table. The caches are keyed by URL, so
		-- the two never bleed into one another.
		assert.is_true(vim.tbl_contains(mysql_names, "Users"))

		local pg_names = vim.tbl_map(function(t)
			return t.name
		end, schema.get_tables(pg.url, "public"))
		assert.is_false(vim.tbl_contains(pg_names, "Users"))

		assert.is_true(schema.has_cache(mysql.url))
		assert.is_true(schema.has_cache(pg.url))
		assert.are_not.same(mysql_schemas, pg_schemas)
	end)

	it("closing one leaves the other open", function()
		workbench.open_for("mysql-test")
		local pg = workbench.open_for("postgres-test")

		workbench.close("mysql-test")

		assert.is_nil(workbench.get("mysql-test"))
		assert.is_not_nil(workbench.get("postgres-test"))
		assert.is_true(pg:is_open())
		assert.are.same({ "postgres-test" }, workbench.open_names())
	end)
end)
