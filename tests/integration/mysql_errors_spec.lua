-- End-to-end failure tests against a real MySQL server.
--
-- The point of these is that the user must never be left staring at an empty
-- pane: every bad connection string and every bad query has to come back with
-- the client's own message intact.
--
-- Skipped automatically when no server is reachable. Override the target with
--   DBAB_TEST_MYSQL_URL=mysql://user:pass@host:3306/db make test-integration

local config = require("dbab.config")
local executor = require("dbab.core.executor")
local schema = require("dbab.core.schema")

local ADMIN_URL = os.getenv("DBAB_TEST_MYSQL_URL") or "mysql://root:root@127.0.0.1:3306/testdb"

config.setup({ connections = { { name = "integration", url = ADMIN_URL } } })

---@return boolean ok, string reason
local function probe()
	if vim.fn.executable("mysql") == 0 and vim.fn.executable("mariadb") == 0 then
		return false, "no mysql client on PATH"
	end

	local out = executor.execute(ADMIN_URL, "SELECT 1;")
	if out == nil or vim.trim(out) == "" then
		return false, "no MySQL server reachable at " .. ADMIN_URL
	end
	if executor.is_error(out) then
		return false, "MySQL refused the connection: " .. vim.split(out, "\n")[1]
	end

	return true, ""
end

local reachable, reason = probe()

describe("mysql error reporting", function()
	if not reachable then
		it("is skipped", function()
			pending("mysql integration tests skipped: " .. reason)
		end)
		return
	end

	before_each(function()
		schema.clear_cache()
	end)

	after_each(function()
		schema.clear_cache()
	end)

	--- Every failure must produce non-empty output that is recognised as an
	--- error, otherwise the result pane renders "No results returned".
	---@param raw string
	local function assert_reported(raw)
		assert.is_not_nil(raw)
		assert.are_not.equal("", vim.trim(raw))
		assert.is_true(executor.is_error(raw), "not recognised as an error: " .. vim.inspect(raw))
	end

	describe("invalid connection strings", function()
		it("reports an unknown host", function()
			local raw = executor.execute("mysql://root:root@nonexistent-host-xyz:3306/testdb", "SELECT 1;")

			assert_reported(raw)
			assert.is_not_nil(raw:match("Unknown MySQL server host"))
		end)

		it("reports a refused connection", function()
			local raw = executor.execute("mysql://root:root@127.0.0.1:59999/testdb", "SELECT 1;")

			assert_reported(raw)
			assert.is_not_nil(raw:match("Can't connect to MySQL server"))
		end)

		it("reports a wrong password", function()
			local raw = executor.execute("mysql://root:definitely-wrong@127.0.0.1:3306/testdb", "SELECT 1;")

			assert_reported(raw)
			assert.is_not_nil(raw:match("Access denied"))
		end)

		it("reports an unknown database", function()
			local raw = executor.execute("mysql://root:root@127.0.0.1:3306/no_such_database", "SELECT 1;")

			assert_reported(raw)
			assert.is_not_nil(raw:match("Unknown database"))
		end)

		it("reports a URL with an empty database component", function()
			-- `ctx:db()` style config produces a trailing slash and no database.
			local raw = executor.execute("mysql://root:root@127.0.0.1:3306/", "SELECT 1;")

			assert_reported(raw)
		end)

		it("reports an unsupported scheme rather than returning nothing", function()
			local raw = executor.execute("redis://localhost:6379/0", "PING")

			assert_reported(raw)
			assert.is_not_nil(raw:match("Unsupported database type"))
		end)
	end)

	describe("invalid queries", function()
		it("reports a syntax error", function()
			local raw = executor.execute(ADMIN_URL, "SELEKT 1;")

			assert_reported(raw)
			assert.is_not_nil(raw:match("^ERROR 1064 "))
			assert.is_not_nil(raw:match("SQL syntax"))
		end)

		it("reports a missing table", function()
			local raw = executor.execute(ADMIN_URL, "SELECT * FROM definitely_not_a_table;")

			assert_reported(raw)
			assert.is_not_nil(raw:match("^ERROR 1146 "))
			assert.is_not_nil(raw:match("doesn't exist"))
		end)

		it("reports a missing column", function()
			local raw = executor.execute(ADMIN_URL, "SELECT nope FROM information_schema.tables LIMIT 1;")

			assert_reported(raw)
			assert.is_not_nil(raw:match("^ERROR 1054 "))
			assert.is_not_nil(raw:match("Unknown column"))
		end)

		it("reports a constraint violation", function()
			executor.execute(ADMIN_URL, "DROP TABLE IF EXISTS dbab_err_test;")
			executor.execute(ADMIN_URL, "CREATE TABLE dbab_err_test (id INT PRIMARY KEY);")
			executor.execute(ADMIN_URL, "INSERT INTO dbab_err_test (id) VALUES (1);")

			local raw = executor.execute(ADMIN_URL, "INSERT INTO dbab_err_test (id) VALUES (1);")

			executor.execute(ADMIN_URL, "DROP TABLE IF EXISTS dbab_err_test;")

			assert_reported(raw)
			assert.is_not_nil(raw:match("Duplicate entry"))
		end)

		it("keeps the password warning out of the error message", function()
			local raw = executor.execute(ADMIN_URL, "SELECT * FROM definitely_not_a_table;")

			assert.is_nil(raw:match("%[Warning%]"))
			assert.is_nil(raw:match("insecure"))
			-- The error must be the very first thing the pane shows.
			assert.is_not_nil(raw:match("^ERROR "))
		end)

		it("does not mistake a successful query for an error", function()
			local raw = executor.execute(ADMIN_URL, "SELECT 1 AS a;")

			assert.is_false(executor.is_error(raw))
		end)
	end)

	describe("async execution", function()
		it("passes the error to the callback instead of dropping it", function()
			local done, result, err = false, nil, nil

			executor.execute_async(ADMIN_URL, "SELECT * FROM definitely_not_a_table;", function(res, e)
				result, err, done = res, e, true
			end)

			vim.wait(10000, function()
				return done
			end)

			assert.is_true(done, "async callback never fired")
			assert.is_not_nil(err)
			assert.is_not_nil(err:match("ERROR 1146"))
			assert.are.equal("", result)
		end)

		it("reports a bad connection to the callback", function()
			local done, err = false, nil

			executor.execute_async("mysql://root:root@127.0.0.1:59999/testdb", "SELECT 1;", function(_, e)
				err, done = e, true
			end)

			vim.wait(10000, function()
				return done
			end)

			assert.is_true(done, "async callback never fired")
			assert.is_not_nil(err)
			assert.is_not_nil(err:match("Can't connect to MySQL server"))
		end)
	end)

	describe("schema browser", function()
		it("does not cache an error as an empty schema list", function()
			local bad_url = "mysql://root:definitely-wrong@127.0.0.1:3306/testdb"

			local schemas = schema.get_schemas(bad_url)

			-- It still returns a list, but must not have cached the failure as a
			-- legitimate "this database has no schemas" answer.
			assert.are.equal(0, #schemas)
			assert.is_false(schema.has_cache(bad_url))
		end)

		it("caches a successful lookup", function()
			local schemas = schema.get_schemas(ADMIN_URL)

			assert.is_true(#schemas > 0)
			assert.is_true(schema.has_cache(ADMIN_URL))
		end)
	end)
end)
