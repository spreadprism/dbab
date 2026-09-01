-- End-to-end tests against a real MySQL server.
--
-- These exercise the whole stack -- adapter -> executor -> parser -> schema --
-- against live output from the `mysql` CLI, which is where the format bugs
-- live. They are skipped automatically when no server is reachable, so the
-- suite still passes on a machine without one.
--
-- Point them somewhere else with:
--   DBAB_TEST_MYSQL_URL=mysql://user:pass@host:3306/db make test

local config = require("dbab.config")
local executor = require("dbab.core.executor")
local parser = require("dbab.utils.parser")
local schema = require("dbab.core.schema")

local ADMIN_URL = os.getenv("DBAB_TEST_MYSQL_URL") or "mysql://root:mysql@127.0.0.1:3306/mysql"
local TEST_DB = "dbab_integration_test"
local TEST_TABLE = "widgets"

--- Swap the database component of a connection URL.
---@param url string
---@param database string
---@return string
local function with_database(url, database)
	return (url:gsub("/[^/]*$", "/" .. database))
end

local TEST_URL = with_database(ADMIN_URL, TEST_DB)

config.setup({ connections = { { name = "integration", url = TEST_URL } } })

--- Is a MySQL server actually reachable?
---@return boolean ok, string reason
local function probe()
	if vim.fn.executable("mysql") == 0 and vim.fn.executable("mariadb") == 0 then
		return false, "no mysql client on PATH"
	end

	local out = executor.execute(ADMIN_URL, "SELECT 1;")
	if out == nil or vim.trim(out) == "" then
		return false, "no MySQL server reachable at " .. ADMIN_URL
	end
	if out:match("^ERROR") then
		return false, "MySQL refused the connection: " .. vim.split(out, "\n")[1]
	end

	return true, ""
end

local reachable, reason = probe()

---@param sql string
---@return string
local function run(sql)
	return executor.execute(TEST_URL, sql)
end

---@param sql string
---@return Dbab.QueryResult
local function query(sql)
	return parser.parse(run(sql), "table", "mysql")
end

describe("mysql integration", function()
	if not reachable then
		it("is skipped", function()
			pending("mysql integration tests skipped: " .. reason)
		end)
		return
	end

	before_each(function()
		executor.execute(ADMIN_URL, "CREATE DATABASE IF NOT EXISTS " .. TEST_DB .. ";")

		run(("DROP TABLE IF EXISTS %s;"):format(TEST_TABLE))
		run(([[
			CREATE TABLE %s (
				id INT NOT NULL AUTO_INCREMENT,
				name VARCHAR(64) NOT NULL,
				price DECIMAL(8,2) NULL,
				note VARCHAR(64) NULL,
				PRIMARY KEY (id)
			);
		]]):format(TEST_TABLE))

		schema.clear_cache()
	end)

	after_each(function()
		-- Drops the table with it, and leaves nothing behind on the server.
		executor.execute(ADMIN_URL, "DROP DATABASE IF EXISTS " .. TEST_DB .. ";")
		schema.clear_cache()
	end)

	local function insert_fixtures()
		run(([[
			INSERT INTO %s (name, price, note) VALUES
				('widget', 9.99, 'first'),
				('gadget', 19.50, NULL),
				('doohickey', 0.01, 'last');
		]]):format(TEST_TABLE))
	end

	describe("create table", function()
		it("creates a table the schema browser can see", function()
			local tables = schema.get_tables(TEST_URL, TEST_DB)

			local names = vim.tbl_map(function(t)
				return t.name
			end, tables)

			assert.is_true(vim.tbl_contains(names, TEST_TABLE))
		end)

		it("reports the columns, their types and the primary key", function()
			local columns = schema.get_columns(TEST_URL, TEST_TABLE)

			assert.are.equal(4, #columns)

			assert.are.equal("id", columns[1].name)
			assert.are.equal("int", columns[1].data_type)
			assert.is_false(columns[1].is_nullable)
			assert.is_true(columns[1].is_primary)

			assert.are.equal("name", columns[2].name)
			assert.are.equal("varchar", columns[2].data_type)
			assert.is_false(columns[2].is_nullable)
			assert.is_false(columns[2].is_primary)

			assert.are.equal("price", columns[3].name)
			assert.is_true(columns[3].is_nullable)
		end)
	end)

	describe("insert rows", function()
		it("reports the inserted rows back on select", function()
			insert_fixtures()

			local result = query(("SELECT id, name FROM %s ORDER BY id;"):format(TEST_TABLE))

			assert.are.equal(3, result.row_count)
			assert.are.equal(3, #result.rows)
		end)

		it("counts the inserted rows in a single column result", function()
			insert_fixtures()

			-- Single-column MySQL output carries no tab to identify the format
			-- by, so this is the case that used to lose the header row.
			local result = query(("SELECT COUNT(*) AS total FROM %s;"):format(TEST_TABLE))

			assert.are.same({ "total" }, result.columns)
			assert.are.same({ { "3" } }, result.rows)
			assert.are.equal(1, result.row_count)
		end)

		it("inserts nothing when the table is left empty", function()
			local result = query(("SELECT id FROM %s;"):format(TEST_TABLE))

			assert.are.equal(0, result.row_count)
			assert.are.equal(0, #result.rows)
		end)
	end)

	describe("select values", function()
		before_each(insert_fixtures)

		it("returns every column in declaration order", function()
			local result = query(("SELECT id, name, price, note FROM %s ORDER BY id;"):format(TEST_TABLE))

			assert.are.same({ "id", "name", "price", "note" }, result.columns)
		end)

		it("returns the cell values of a single row", function()
			local result = query(("SELECT id, name, price FROM %s WHERE name = 'widget';"):format(TEST_TABLE))

			assert.are.equal(1, result.row_count)
			assert.are.same({ "1", "widget", "9.99" }, result.rows[1])
		end)

		it("returns rows in the requested order", function()
			local result = query(("SELECT name FROM %s ORDER BY price DESC;"):format(TEST_TABLE))

			assert.are.same({ { "gadget" }, { "widget" }, { "doohickey" } }, result.rows)
		end)

		it("represents a NULL cell distinctly from a value", function()
			local result = query(("SELECT name, note FROM %s ORDER BY id;"):format(TEST_TABLE))

			assert.are.same({ "widget", "first" }, result.rows[1])
			assert.are.same({ "gadget", "NULL" }, result.rows[2])
		end)

		it("filters with a WHERE clause", function()
			local result = query(("SELECT name FROM %s WHERE price > 5 ORDER BY name;"):format(TEST_TABLE))

			assert.are.same({ { "gadget" }, { "widget" } }, result.rows)
		end)

		it("returns no rows when nothing matches", function()
			local result = query(("SELECT name FROM %s WHERE name = 'nope';"):format(TEST_TABLE))

			assert.are.equal(0, result.row_count)
		end)

		it("sees an update", function()
			run(("UPDATE %s SET price = 42.00 WHERE name = 'widget';"):format(TEST_TABLE))

			local result = query(("SELECT price FROM %s WHERE name = 'widget';"):format(TEST_TABLE))

			assert.are.same({ { "42.00" } }, result.rows)
		end)

		it("sees a delete", function()
			run(("DELETE FROM %s WHERE name = 'gadget';"):format(TEST_TABLE))

			local result = query(("SELECT COUNT(*) AS total FROM %s;"):format(TEST_TABLE))

			assert.are.same({ { "2" } }, result.rows)
		end)
	end)

	describe("client noise and errors", function()
		it("keeps the password warning out of the result", function()
			insert_fixtures()

			local raw = run(("SELECT name FROM %s LIMIT 1;"):format(TEST_TABLE))

			assert.is_nil(raw:match("%[Warning%]"))
			assert.is_nil(raw:match("insecure"))
		end)

		it("surfaces a mysql error verbatim", function()
			local raw = run("SELECT * FROM definitely_not_a_table;")

			assert.is_not_nil(raw:match("^ERROR %d+ "))
		end)
	end)
end)
