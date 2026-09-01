local keywords = require("dbab.ui.keywords")
local config = require("dbab.config")

-- Keyword casing is driven by the `sql` treesitter grammar, which already knows
-- the difference between a keyword, an identifier, a string and a comment. That
-- is the whole reason not to do this with a word list.
describe("keyword uppercasing", function()
	local buf

	before_each(function()
		config.setup({})
		buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].filetype = "sql"
	end)

	after_each(function()
		if buf and vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
		buf = nil
	end)

	---@param sql string|string[]
	---@return string
	local function run(sql)
		local lines = type(sql) == "table" and sql or { sql }
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		keywords.uppercase(buf)

		return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end

	it("uppercases the basic clauses", function()
		assert.are.equal("SELECT * FROM Users", run("select * from Users"))
	end)

	it("leaves table and column names alone", function()
		assert.are.equal("SELECT id, userName FROM MyTable", run("select id, userName from MyTable"))
	end)

	it("does not reach inside a string literal", function()
		assert.are.equal("SELECT id FROM t WHERE a = 'select from me'", run("select id from t where a = 'select from me'"))
	end)

	it("does not reach inside a comment", function()
		assert.are.equal("SELECT * FROM t -- and from here", run("select * from t -- and from here"))
	end)

	it("does not touch a quoted identifier that happens to be a keyword", function()
		assert.are.equal([[SELECT "order" FROM "select"]], run([[select "order" from "select"]]))
	end)

	it("handles joins and clause keywords", function()
		assert.are.equal(
			"SELECT a FROM t LEFT JOIN u ON t.id = u.t_id GROUP BY a ORDER BY a DESC LIMIT 10",
			run("select a from t left join u on t.id = u.t_id group by a order by a desc limit 10")
		)
	end)

	it("handles insert, update and delete", function()
		assert.are.equal("INSERT INTO t (a) VALUES (1);", run("insert into t (a) values (1);"))
		assert.are.equal("UPDATE t SET a = 1 WHERE id = 2", run("update t set a = 1 where id = 2"))
		assert.are.equal("DELETE FROM t WHERE id = 1", run("delete from t where id = 1"))
	end)

	it("handles a CASE expression", function()
		assert.are.equal("SELECT CASE WHEN a THEN b ELSE c END FROM t", run("select case when a then b else c end from t"))
	end)

	it("works across several lines", function()
		assert.are.equal("SELECT *\nFROM t\nWHERE id = 1", run({ "select *", "from t", "where id = 1" }))
	end)

	it("reports no change when everything is already uppercase", function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT * FROM t" })

		assert.is_false(keywords.uppercase(buf))
	end)

	it("does not mark an already-uppercase buffer modified", function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT * FROM t" })
		vim.bo[buf].modified = false

		keywords.uppercase(buf)

		assert.is_false(vim.bo[buf].modified)
	end)

	it("preserves byte length so the cursor cannot drift", function()
		local before = "select * from Users where id = 1"
		local after = run(before)

		assert.are.equal(#before, #after)
	end)

	it("refuses a non-modifiable buffer", function()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "select 1" })
		vim.bo[buf].modifiable = false

		assert.is_false(keywords.uppercase(buf))
	end)

	describe("attach", function()
		it("uppercases when insert mode is left", function()
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
			keywords.attach(buf)

			vim.api.nvim_win_set_buf(0, buf)
			vim.api.nvim_feedkeys("iselect * from t", "x", false)
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
			vim.wait(200, function()
				return false
			end)

			assert.are.equal("SELECT * FROM t", vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1])
		end)

		it("does nothing when the option is off", function()
			config.setup({ editor = { upper_keywords = false } })

			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
			keywords.attach(buf)

			vim.api.nvim_win_set_buf(0, buf)
			vim.api.nvim_feedkeys("iselect * from t", "x", false)
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
			vim.wait(200, function()
				return false
			end)

			assert.are.equal("select * from t", vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1])
		end)
	end)
end)
