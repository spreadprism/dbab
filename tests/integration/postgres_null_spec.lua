-- NULL, an empty string and the literal text 'NULL' are three different values.
-- Out of the box a client prints the first two identically, so dbab asks for a
-- sentinel (`psql --pset=null=\N`) and turns it back into `vim.NIL` at parse
-- time. These tests prove the round trip against a real server.

local config = require("dbab.config")
local executor = require("dbab.core.executor")
local parser = require("dbab.utils.parser")

local PG_URL = os.getenv("DBAB_TEST_PG_URL") or "postgres://postgres:postgres@127.0.0.1:5432/testdb"

config.setup({ connections = { { name = "pg", url = PG_URL } } })

---@return boolean ok, string reason
local function probe()
	if vim.fn.executable("psql") == 0 then
		return false, "no psql on PATH"
	end

	local out = executor.execute(PG_URL, "SELECT 1;")
	if out == nil or vim.trim(out) == "" then
		return false, "no PostgreSQL server at " .. PG_URL
	end
	if executor.is_error(out) then
		return false, vim.split(out, "\n")[1]
	end

	return true, ""
end

local reachable, reason = probe()

describe("postgres null handling", function()
	if not reachable then
		it("is skipped", function()
			pending("postgres integration tests skipped: " .. reason)
		end)
		return
	end

	---@param sql string
	---@return Dbab.QueryResult
	local function query(sql)
		return parser.parse(executor.execute(PG_URL, sql), "table", "postgres")
	end

	it("distinguishes NULL, empty string and the text 'NULL'", function()
		local result = query([[SELECT NULL::text AS a, '' AS b, 'NULL' AS c;]])

		assert.are.equal(vim.NIL, result.rows[1][1])
		assert.are.equal("", result.rows[1][2])
		assert.are.equal("NULL", result.rows[1][3])
	end)

	it("prints a real null as NULL", function()
		local result = query("SELECT NULL::text AS a;")

		assert.are.equal("NULL", parser.display(result.rows[1][1]))
	end)

	it("prints an empty string as blank", function()
		local result = query("SELECT '' AS a;")

		assert.are.equal("", parser.display(result.rows[1][1]))
	end)

	it("keeps a null in place so later columns stay aligned", function()
		-- A Lua nil would leave a hole and shorten the row; vim.NIL does not.
		local result = query([[SELECT NULL::text AS a, 'x' AS b, NULL::int AS c, 'y' AS d;]])

		assert.are.equal(4, #result.rows[1])
		assert.are.equal("x", result.rows[1][2])
		assert.are.equal("y", result.rows[1][4])
	end)

	it("renders the row with separators and an aligned NULL", function()
		local result = query([[SELECT NULL::text AS a, 'x' AS b;]])
		local widths = parser.calculate_column_widths(result)
		local line = parser.render_row(result.rows[1], widths)

		assert.are.equal(" NULL | x ", line)
	end)

	it("does not mistake a value containing the sentinel text for a null", function()
		-- A literal backslash-N is the one value the sentinel cannot represent.
		local result = query([[SELECT 'x' || chr(92) || 'Ny' AS a;]])

		assert.are.equal([[x\Ny]], result.rows[1][1])
	end)
end)
